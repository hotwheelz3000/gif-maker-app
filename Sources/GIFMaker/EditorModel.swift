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

    @Published var isReady = false
    @Published var loadError: String?
    @Published var duration: Double = 0
    @Published var videoSize: CGSize = .zero
    @Published var thumbnails: [UIImage] = []
    @Published var currentTime: Double = 0
    @Published var canReverse = false

    // Trim
    @Published var start: Double = 0
    @Published var end: Double = 0

    // Crop (center is in video pixels, top-left origin)
    @Published var aspect: CropAspect = .original { didSet { zoom = 1; normalizeCenter() } }
    @Published var zoom: CGFloat = 1
    @Published var center: CGPoint = .zero

    // Output
    @Published var loopMode: LoopMode = .normal { didSet { if isReady { restartLoop() } } }
    @Published var speed: Double = 1 {
        didSet { if player.rate != 0 { player.rate = direction < 0 ? reverseRate : Float(speed) } }
    }
    @Published var width: Int = 720
    @Published var fps: Int = 14

    // Export
    @Published var isExporting = false
    @Published var progress: Double = 0
    @Published var exportError: String?
    @Published var result: GIFResult?

    nonisolated(unsafe) private var timer: Timer?
    private var direction: Float = 1
    private var isActive = false
    private var isSeeking = false
    private var isScrubbing = false
    private var exportTask: Task<Void, Never>?

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: Loading

    func load() async {
        guard !isReady else { return }
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
            start = 0
            end = min(duration, 5)
            center = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
            isReady = true
            startPlayback()
            await makeThumbnails()
        } catch {
            loadError = "Couldn't read this video: \(error.localizedDescription)"
        }
    }

    private func makeThumbnails() async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let count = 10
        let times = (0..<count).map { i in
            CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        }
        var images: [UIImage] = []
        for await item in gen.images(for: times) {
            if let cg = try? item.image { images.append(UIImage(cgImage: cg)) }
        }
        thumbnails = images
    }

    // MARK: Playback (loops the trimmed range in the chosen loop style)

    /// True when the preview can actually play backwards for this video.
    var previewShowsLoopMode: Bool { loopMode == .normal || canReverse }

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
        player.playImmediately(atRate: direction < 0 ? reverseRate : Float(speed))
    }

    func pause() {
        isActive = false
        player.pause()
    }

    func scrub(to seconds: Double) {
        isScrubbing = true
        player.pause()
        guard !isSeeking else { return }
        isSeeking = true
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            isSeeking = false
        }
    }

    func endScrub() {
        isScrubbing = false
        restartLoop()
    }

    // MARK: Trim

    func setStart(_ value: Double) {
        var v = min(max(0, value), end - Self.minClip)
        v = max(v, 0)
        if end - v > Self.maxClip { end = v + Self.maxClip }
        start = v
    }

    func setEnd(_ value: Double) {
        var v = max(min(duration, value), start + Self.minClip)
        v = min(v, duration)
        if v - start > Self.maxClip { start = v - Self.maxClip }
        end = v
    }

    var clipLength: Double { max(0, end - start) }

    /// Slides the whole selection, keeping its length.
    func moveSelection(start newStart: Double) {
        let len = end - start
        let s = min(max(0, newStart), max(0, duration - len))
        start = s
        end = s + len
    }

    func nudgeStart(_ delta: Double) {
        setStart(start + delta)
        restartLoop()
    }

    func nudgeEnd(_ delta: Double) {
        setEnd(end + delta)
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

    func resetCrop() {
        zoom = 1
        center = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
    }

    // MARK: Output info

    var outputSize: CGSize {
        let r = cropRect
        guard r.width > 0 else { return .zero }
        var w = min(CGFloat(width), r.width.rounded(.down))
        w = max(2, (w / 2).rounded(.down) * 2)
        let h = max(2, (w * r.height / r.width / 2).rounded() * 2)
        return CGSize(width: w, height: h)
    }

    var estimatedFrames: Int {
        let forward = Int((clipLength * Double(fps) / speed).rounded(.up))
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
        pause()
        let settings = GIFSettings(
            videoURL: url, start: start, end: end, crop: cropRect, videoSize: videoSize,
            outputSize: outputSize, fps: fps, speed: speed, loopMode: loopMode
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
