import AVFoundation
import SwiftUI
import UIKit

enum CropAspect: String, CaseIterable, Identifiable {
    case original = "Original"
    case square = "1:1"
    case threeTwo = "3:2"
    case wide = "16:9"
    case fourFive = "4:5"
    case tall = "9:16"

    var id: String { rawValue }

    func ratio(for videoSize: CGSize) -> CGFloat {
        switch self {
        case .original: return videoSize.width / max(videoSize.height, 1)
        case .square: return 1
        case .threeTwo: return 3.0 / 2.0
        case .wide: return 16.0 / 9.0
        case .fourFive: return 4.0 / 5.0
        case .tall: return 9.0 / 16.0
        }
    }
}

enum LoopMode: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case reverse = "Reverse"
    case boomerang = "Boomerang"
    var id: String { rawValue }
}

struct GIFResult: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let frameCount: Int
    let pixelSize: CGSize
    let loopMode: LoopMode
    let bytes: Int

    static func == (a: GIFResult, b: GIFResult) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

@MainActor
final class EditorModel: ObservableObject {
    static let maxClip: Double = 15
    static let minClip: Double = 0.3

    let url: URL
    let asset: AVURLAsset
    nonisolated(unsafe) let player: AVPlayer
    /// Set when editing a GIF: frames are read straight from the file (no video step).
    let gif: GIFSource?
    /// True when a GIF was picked (even if it then couldn't be read).
    let isGIF: Bool

    @Published var isReady = false
    @Published var loadError: String?
    @Published var duration: Double = 0
    @Published var videoSize: CGSize = .zero
    // Trim-bar previews (nil = not loaded yet). The version lets the strip redraw only
    // when a picture changes.
    @Published var thumbnails: [UIImage?] = [] { didSet { thumbnailsVersion &+= 1 } }
    private(set) var thumbnailsVersion = 0
    @Published var isLoadingThumbnails = false
    @Published var thumbnailError: String?
    /// Number of previews across the whole video (more for long videos, so the
    /// zoomed-in strip still has enough pictures).
    var thumbnailCount: Int {
        guard duration > Self.windowMax else { return 10 }
        return min(40, Int((10 * duration / Self.windowMax).rounded(.up)))
    }

    // Strip zoom: the trim bar shows at most this many seconds at once.
    static let windowMax: Double = 30
    @Published var windowStart: Double = 0
    var windowLength: Double { min(duration, Self.windowMax) }

    /// Centers the visible window on the selection.
    func recenterWindow() {
        let mid = (start + end) / 2
        windowStart = min(max(0, mid - windowLength / 2), max(0, duration - windowLength))
    }

    /// Recenters only if part of the selection is outside the visible window.
    func keepSelectionVisible() {
        if start < windowStart - 0.001 || end > windowStart + windowLength + 0.001 { recenterWindow() }
    }

    /// Playhead time lives in its own small object so updating it 30 times a second
    /// only redraws the playhead, not the whole editor.
    let clock = PlaybackClock()
    var currentTime: Double {
        get { clock.time }
        set { if clock.time != newValue { clock.time = newValue } }
    }
    /// Whether the video player can play this video backwards (only used as a fallback
    /// if the frame preview below can't read the clip).
    @Published var canReverse = false

    // Trim
    @Published var start: Double = 0
    @Published var end: Double = 0

    // Crop (center is in video pixels, top-left origin)
    @Published var aspect: CropAspect = .original { didSet { zoom = 1; normalizeCenter() } }
    @Published var zoom: CGFloat = 1
    @Published var center: CGPoint = .zero

    // Output
    @Published var loopMode: LoopMode = .normal {
        didSet {
            framePreviewFailed = false
            if isReady { restartLoop() }
        }
    }
    @Published var speed: Double = 1 {
        didSet {
            if usesFramePreview { if isReady { restartLoop() } }
            else if player.rate != 0 { player.rate = direction < 0 ? reverseRate : Float(speed) }
        }
    }
    @Published var width: Int = 720
    @Published var fps: Int = 15 { didSet { if usesFramePreview && isReady { restartLoop() } } }

    // Frame preview for Reverse / Boomerang. The video player can't play backwards
    // smoothly (phone videos only decode smoothly forwards), so the clip's frames are
    // read ahead of time, like the GIF export does, and played in loop order.
    @Published private(set) var previewFrames: [Data] = []
    /// Seconds each prepared frame shows (by frame index).
    @Published private(set) var previewDurations: [Double] = []
    /// Single frame shown for a GIF while dragging or while its preview is prepared.
    @Published private(set) var stillImage: UIImage?
    @Published private(set) var previewFramesID = UUID()
    @Published private(set) var isPreparingPreview = false
    private var framePreviewFailed = false
    private var previewKey = ""
    private var previewTask: Task<Void, Never>?

    /// GIFs always use the frame preview; videos only for Reverse and Boomerang.
    var usesFramePreview: Bool { isGIF || (loopMode != .normal && !framePreviewFailed) }

    /// True when the frame player (not the video player) should be on screen.
    var showsFramePreview: Bool {
        usesFramePreview && !previewFrames.isEmpty && !isPreparingPreview && !isScrubbing
    }

    /// Order to play the prepared frames in, matching the GIF.
    var previewOrder: [Int] {
        let n = previewFrames.count
        guard n > 0 else { return [] }
        switch loopMode {
        case .normal: return Array(0..<n)
        case .reverse: return Array((0..<n).reversed())
        case .boomerang:
            let back = n > 2 ? Array((1..<(n - 1)).reversed()) : []
            return Array(0..<n) + back
        }
    }

    // Export
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var exportError: String?
    @Published var result: GIFResult?

    nonisolated(unsafe) private var timer: Timer?
    private var direction: Float = 1
    private var isActive = false
    private var isSeeking = false
    @Published private(set) var isScrubbing = false
    private var exportTask: Task<Void, Never>?

    init(url: URL, isGIF: Bool = false) {
        self.url = url
        self.isGIF = isGIF
        self.asset = AVURLAsset(url: url)
        if isGIF {
            // GIFs never use the video player; it stays empty.
            self.gif = GIFSource(url: url)
            self.player = AVPlayer()
            // Original size and timing by default, so nothing is lost.
            self.width = 0
            self.fps = 0
        } else {
            self.gif = nil
            self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Loading

    func load() async {
        guard !isReady else { return }
        if isGIF {
            await loadGIF()
            return
        }
        do {
            let d = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                loadError = "This file has no video track."
                return
            }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            videoSize = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
            duration = d.isFinite ? d : 0
            guard duration >= Self.minClip else {
                loadError = "This video is too short to make a GIF."
                return
            }
            start = 0
            end = min(duration, 5)
            recenterWindow()
            center = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
            isReady = true
            // Previews first, then playback: the video decoder can't reliably do both at once.
            // (Unstructured task so it isn't cancelled along with the view's .task.)
            await Task { await self.makeThumbnails() }.value
            startPlayback()
        } catch {
            loadError = "Couldn't read this video: \(error.localizedDescription)"
        }
    }

    private func loadGIF() async {
        guard let gif else {
            loadError = "Couldn't read that GIF."
            return
        }
        videoSize = gif.size
        duration = gif.duration
        guard duration >= Self.minClip else {
            loadError = "This GIF is too short to edit."
            return
        }
        start = 0
        end = min(duration, Self.maxClip)   // the whole GIF (up to 15 s) starts selected
        recenterWindow()
        center = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        stillImage = Self.previewImage(gif, at: 0)
        isReady = true
        await Task { await self.makeThumbnails() }.value
        startPlayback()
    }

    /// One GIF frame, scaled down for the preview.
    nonisolated static func previewImage(_ gif: GIFSource, at t: Double) -> UIImage? {
        guard let cg = gif.image(at: gif.frameIndex(at: t)) else { return nil }
        let scale = min(1, 720 / max(gif.size.width, gif.size.height))
        let size = CGSize(width: gif.size.width * scale, height: gif.size.height * scale)
        guard let small = GIFExporter.render(
            cg, crop: CGRect(origin: .zero, size: gif.size), videoSize: gif.size, outSize: size
        ) else { return nil }
        return UIImage(cgImage: small)
    }

    /// Loads the trim-bar previews into fixed slots, the same way the GIF export reads
    /// frames (one batch request), then retries any misses one at a time.
    private func makeThumbnails() async {
        isLoadingThumbnails = true
        thumbnailError = nil
        defer { isLoadingThumbnails = false }

        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        let tolerance = CMTime(seconds: max(duration / 40, 0.1), preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        let count = thumbnailCount
        thumbnails = Array(repeating: nil, count: count)

        if let gif {
            let d = duration
            thumbnails = await Task.detached {
                (0..<count).map { i -> UIImage? in
                    let t = d * (Double(i) + 0.5) / Double(count)
                    return gif.image(at: gif.frameIndex(at: t)).map { Self.small($0) }
                }
            }.value
            if thumbnails.allSatisfy({ $0 == nil }) { thumbnailError = "Couldn't load previews." }
            return
        }

        var slotForTime: [Int64: Int] = [:]
        var times: [CMTime] = []
        for i in 0..<count {
            let fraction: Double = (Double(i) + 0.5) / Double(count)
            let seconds: Double = duration * fraction
            let value = Int64((seconds * 600).rounded())
            let t = CMTime(value: value, timescale: 600)
            slotForTime[t.value] = i
            times.append(t)
        }

        var lastError: Error?
        for await item in gen.images(for: times) {
            let key = CMTimeConvertScale(item.requestedTime, timescale: 600, method: .roundHalfAwayFromZero).value
            guard let slot = slotForTime[key] else { continue }
            do {
                thumbnails[slot] = Self.small(try item.image)
            } catch {
                lastError = error
            }
        }

        // Retry misses one at a time, nearest frame allowed.
        gen.requestedTimeToleranceBefore = .positiveInfinity
        gen.requestedTimeToleranceAfter = .positiveInfinity
        for attempt in 0..<2 where thumbnails.contains(where: { $0 == nil }) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            for i in 0..<count where thumbnails[i] == nil {
                do {
                    let (cg, _) = try await gen.image(at: times[i])
                    thumbnails[i] = Self.small(cg)
                } catch {
                    lastError = error
                }
            }
        }

        if thumbnails.allSatisfy({ $0 == nil }) {
            thumbnailError = "Couldn't load previews: \(lastError?.localizedDescription ?? "unknown error")"
        }
    }

    /// Scales a frame down to about 240 points tall for the strip.
    private nonisolated static func small(_ cg: CGImage) -> UIImage {
        let full = UIImage(cgImage: cg)
        let scale = min(1, 240 / max(full.size.height, 1))
        let size = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            full.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    // MARK: Playback (loops the trimmed range in the chosen loop style)

    /// False only when neither the frame preview nor the video player can show this
    /// loop style (the GIF itself is still made correctly).
    var previewShowsLoopMode: Bool { loopMode == .normal || !framePreviewFailed || canReverse }

    private var reverseRate: Float {
        guard let item = player.currentItem else { return -1 }
        if speed > 1, item.canPlayFastReverse { return -Float(speed) }
        if speed < 1, item.canPlaySlowReverse { return -Float(speed) }
        return -1
    }

    private func startPlayback() {
        canReverse = player.currentItem?.canPlayReverse ?? false
        // A timer (not a periodic observer) so the loop also restarts when the
        // player has stopped at either end of the video.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        restartLoop()
    }

    private func tick() {
        let t = player.currentTime().seconds
        if usesFramePreview {
            // Frame preview drives itself; hide the playhead unless scrubbing.
            if isScrubbing, t.isFinite { currentTime = t } else if currentTime != -1 { currentTime = -1 }
            return
        }
        if t.isFinite { currentTime = t }
        guard isActive, !isScrubbing, !isSeeking, !isExporting, t.isFinite else { return }
        if !canReverse { canReverse = player.currentItem?.canPlayReverse ?? false }

        let mode: LoopMode = canReverse ? loopMode : .normal
        switch mode {
        case .normal:
            if t >= end - 0.02 || t < start - 0.2 || player.rate == 0 {
                seek(to: start, direction: 1)
            }
        case .reverse:
            if t <= start + 0.02 || t > end + 0.2 || player.rate == 0 {
                seek(to: end, direction: -1)
            }
        case .boomerang:
            if t > end + 0.2 || t < start - 0.2 {
                seek(to: start, direction: 1)
            } else if direction > 0 && t >= end - 0.02 {
                direction = -1
                player.rate = reverseRate
            } else if direction < 0 && t <= start + 0.02 {
                direction = 1
                player.rate = Float(speed)
            } else if player.rate == 0 {
                play()
            }
        }
    }

    /// Starts the loop from the right end for the current loop style.
    func restartLoop() {
        isActive = true
        if usesFramePreview {
            prepareFramePreview()
            return
        }
        previewTask?.cancel()
        isPreparingPreview = false
        if loopMode == .reverse && canReverse {
            seek(to: end, direction: -1)
        } else {
            seek(to: start, direction: 1)
        }
    }

    private func seek(to seconds: Double, direction newDirection: Float) {
        isSeeking = true
        direction = newDirection
        player.pause()
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isSeeking = false
            if isActive && !isScrubbing && !isExporting { play() }
        }
    }

    func play() {
        // In frame-preview mode the video player stays paused (it would compete
        // with the frame reader for the video decoder).
        guard !usesFramePreview else { player.pause(); return }
        player.playImmediately(atRate: direction < 0 ? reverseRate : Float(speed))
    }

    func pause() {
        isActive = false
        player.pause()
        if isPreparingPreview {
            previewTask?.cancel()
            isPreparingPreview = false
        }
    }

    // MARK: Frame preview

    private func prepareFramePreview() {
        player.pause()
        let key = "\(start)|\(end)|\(speed)|\(fps)"
        if key == previewKey && !previewFrames.isEmpty {
            previewTask?.cancel()
            isPreparingPreview = false
            return
        }
        previewTask?.cancel()
        isPreparingPreview = true
        let url = self.url, s = start, e = end, sp = speed, f = fps, gif = self.gif
        if let gif {
            stillImage = Self.previewImage(gif, at: s)
        } else {
            // Show the clip's first frame while preparing.
            Task { _ = await player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        }
        previewTask = Task {
            // Short wait so quick repeated changes only prepare once.
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let made: ([Data], [Double])
            if let gif {
                made = (try? await Task.detached {
                    try Self.makeGIFPreviewFrames(gif, start: s, end: e, speed: sp, fps: f)
                }.value) ?? ([], [])
            } else {
                let frames = (try? await Self.makePreviewFrames(url: url, start: s, end: e, speed: sp, fps: f)) ?? []
                made = (frames, Array(repeating: 1.0 / Double(max(f, 1)), count: frames.count))
            }
            if Task.isCancelled { return }
            if made.0.isEmpty {
                isPreparingPreview = false
                // A GIF keeps showing its still frame; a video falls back to the video player.
                if gif == nil {
                    framePreviewFailed = true
                    restartLoop()
                }
                return
            }
            previewFrames = made.0
            previewDurations = made.1
            previewKey = key
            previewFramesID = UUID()
            isPreparingPreview = false
        }
    }

    /// GIF preview: the planned frames (decoded in order, each once) as small JPEGs.
    nonisolated static func makeGIFPreviewFrames(
        _ gif: GIFSource, start: Double, end: Double, speed: Double, fps: Int
    ) throws -> ([Data], [Double]) {
        let scale = min(1, 720 / max(gif.size.width, gif.size.height))
        let size = CGSize(width: (gif.size.width * scale).rounded(), height: (gif.size.height * scale).rounded())
        let full = CGRect(origin: .zero, size: gif.size)
        var made: [Int: Data] = [:]
        var frames: [Data] = []
        var durations: [Double] = []
        for step in gif.plan(start: start, end: end, speed: speed, fps: fps) {
            try Task.checkCancellation()
            var data = made[step.index]
            if data == nil, let cg = gif.image(at: step.index),
               let small = GIFExporter.render(cg, crop: full, videoSize: gif.size, outSize: size) {
                data = GIFExporter.jpegData(small)
                made[step.index] = data
            }
            if let data {
                frames.append(data)
                durations.append(step.duration)
            }
        }
        return (frames, durations)
    }

    /// Reads the trimmed range forwards (the fast direction) as small JPEGs.
    nonisolated static func makePreviewFrames(
        url: URL, start: Double, end: Double, speed: Double, fps: Int
    ) async throws -> [Data] {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 720)
        let step = speed / Double(max(fps, 1))
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        var times: [CMTime] = []
        var slotForTime: [Int64: Int] = [:]
        var t = start
        while t < end - 0.0001 {
            let value = Int64((t * 600).rounded())
            if slotForTime[value] == nil {
                slotForTime[value] = times.count
                times.append(CMTime(value: value, timescale: 600))
            }
            t += step
        }
        var slots = [Data?](repeating: nil, count: times.count)
        for await item in gen.images(for: times) {
            try Task.checkCancellation()
            let key = CMTimeConvertScale(item.requestedTime, timescale: 600, method: .roundHalfAwayFromZero).value
            if let slot = slotForTime[key], let cg = try? item.image {
                slots[slot] = GIFExporter.jpegData(cg)
            }
        }
        return slots.compactMap { $0 }
    }

    /// Latest position asked for while dragging; seeks always catch up to it.
    private var scrubTarget: Double?

    func scrub(to seconds: Double) {
        if !isScrubbing {
            isScrubbing = true
            player.pause()
        }
        scrubTarget = seconds
        guard !isSeeking else { return }
        if gif != nil { runGIFScrub() } else { runScrubSeek() }
    }

    /// GIF: decode the frame at the latest target off the main thread, then catch up.
    private func runGIFScrub() {
        guard let gif, let seconds = scrubTarget else { return }
        scrubTarget = nil
        isSeeking = true
        Task {
            let img = await Task.detached { Self.previewImage(gif, at: seconds) }.value
            if let img { stillImage = img }
            isSeeking = false
            if isScrubbing && scrubTarget != nil { runGIFScrub() }
        }
    }

    /// Fast (nearest-frame) seek to the latest target, then again if the finger moved on.
    private func runScrubSeek() {
        guard let seconds = scrubTarget else { return }
        scrubTarget = nil
        isSeeking = true
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        Task {
            _ = await player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
            isSeeking = false
            if isScrubbing && scrubTarget != nil { runScrubSeek() }
        }
    }

    func endScrub() {
        scrubTarget = nil
        isScrubbing = false
        restartLoop()   // exact seek to the start of the clip
    }

    // MARK: Trim

    func setStart(_ value: Double) {
        var v = min(max(0, value), end - Self.minClip)
        v = max(v, 0)
        if end - v > Self.maxClip { end = v + Self.maxClip }
        if start != v { start = v }
    }

    func setEnd(_ value: Double) {
        var v = max(min(duration, value), start + Self.minClip)
        v = min(v, duration)
        if v - start > Self.maxClip { start = v - Self.maxClip }
        if end != v { end = v }
    }

    var clipLength: Double { max(0, end - start) }

    /// Slides the whole selection, keeping its length.
    func moveSelection(start newStart: Double) {
        let len = end - start
        let s = min(max(0, newStart), max(0, duration - len))
        if start != s {
            start = s
            end = s + len
        }
    }

    func nudgeStart(_ delta: Double) {
        setStart(start + delta)
        keepSelectionVisible()
        restartLoop()
    }

    func nudgeEnd(_ delta: Double) {
        setEnd(end + delta)
        keepSelectionVisible()
        restartLoop()
    }

    // MARK: Crop

    var cropRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let a = aspect.ratio(for: videoSize)
        var cw: CGFloat
        var ch: CGFloat
        if videoSize.width / videoSize.height > a {
            ch = videoSize.height
            cw = ch * a
        } else {
            cw = videoSize.width
            ch = cw / a
        }
        cw /= zoom
        ch /= zoom
        let cx = min(max(center.x, cw / 2), videoSize.width - cw / 2)
        let cy = min(max(center.y, ch / 2), videoSize.height - ch / 2)
        return CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
    }

    func normalizeCenter() {
        let r = cropRect
        guard r.width > 0 else { return }
        center = CGPoint(x: r.midX, y: r.midY)
    }

    /// Tap alternative to pinching.
    func zoom(by factor: CGFloat) {
        zoom = min(max(zoom * factor, 1), 4)
        normalizeCenter()
    }

    /// Tap alternative to dragging: moves the crop by a tenth of its size.
    func moveCrop(dx: CGFloat, dy: CGFloat) {
        let r = cropRect
        center = CGPoint(x: r.midX + dx * r.width / 10, y: r.midY + dy * r.height / 10)
        normalizeCenter()
    }

    // Whether the crop has room to move in each direction (for greying out the arrows).
    var canMoveLeft: Bool { cropRect.minX > 0.5 }
    var canMoveRight: Bool { cropRect.maxX < videoSize.width - 0.5 }
    var canMoveUp: Bool { cropRect.minY > 0.5 }
    var canMoveDown: Bool { cropRect.maxY < videoSize.height - 0.5 }

    func resetCrop() {
        zoom = 1
        center = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
    }

    // MARK: Output info

    var outputSize: CGSize {
        let r = cropRect
        guard r.width > 0 else { return .zero }
        if width <= 0 {
            // Original: the cropped area at its own pixel size.
            return CGSize(width: max(1, r.width.rounded()), height: max(1, r.height.rounded()))
        }
        var w = min(CGFloat(width), r.width.rounded(.down))
        w = max(2, (w / 2).rounded(.down) * 2)
        let h = max(2, (w * r.height / r.width / 2).rounded() * 2)
        return CGSize(width: w, height: h)
    }

    var estimatedFrames: Int {
        let forward = gif?.plan(start: start, end: end, speed: speed, fps: fps).count
            ?? Int((clipLength * Double(max(fps, 1)) / speed).rounded(.up))
        switch loopMode {
        case .normal, .reverse: return forward
        case .boomerang: return max(forward, forward * 2 - 2)
        }
    }

    // MARK: Export

    func makeGIF() {
        guard !isExporting, isReady else { return }
        isExporting = true
        progress = 0
        exportError = nil
        pause()   // also stops any frame preview being prepared, freeing the decoder
        let settings = GIFSettings(
            videoURL: url, start: start, end: end, crop: cropRect, videoSize: videoSize,
            outputSize: outputSize, fps: fps, speed: speed, loopMode: loopMode,
            gifURL: gif?.url
        )
        exportTask = Task {
            do {
                let made = try await GIFExporter.make(settings) { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
                self.result = made
            } catch is CancellationError {
            } catch {
                self.exportError = error.localizedDescription
            }
            self.isExporting = false
            if self.result == nil { self.restartLoop() }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }
}

/// Holds just the playhead time (see EditorModel.clock).
final class PlaybackClock: ObservableObject {
    @Published var time: Double = 0
}
