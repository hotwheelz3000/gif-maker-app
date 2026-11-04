import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// Shows an AVPlayer, stretched to exactly its frame (the frame keeps the video's aspect).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resize
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {}
}

/// Plays a GIF file frame by frame straight from disk (low memory).
struct GIFPlayerView: UIViewRepresentable {
    let url: URL

    final class Coordinator { var stopped = false }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let coordinator = context.coordinator
        _ = CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak v] _, image, stop in
            guard !coordinator.stopped, let v else {
                stop.pointee = true
                return
            }
            v.image = UIImage(cgImage: image)
        }
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {}

    static func dismantleUIView(_ v: UIImageView, coordinator: Coordinator) {
        coordinator.stopped = true
    }
}

/// Plays prepared JPEG frames in a given order, each for its own duration, driven by the
/// screen refresh (CADisplayLink). Frames are decoded a few ahead on a background queue so
/// playback never waits on decoding.
struct FramePlayerView: UIViewRepresentable {
    let frames: [Data]
    let framesID: UUID
    let order: [Int]
    /// Seconds each frame shows, by frame index (same length as frames).
    let durations: [Double]

    func makeUIView(context: Context) -> FramePlayerUIView {
        let v = FramePlayerUIView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.contentMode = .scaleToFill
        v.clipsToBounds = true
        v.isUserInteractionEnabled = false
        v.configure(frames: frames, id: framesID, order: order, durations: durations)
        return v
    }

    func updateUIView(_ v: FramePlayerUIView, context: Context) {
        v.configure(frames: frames, id: framesID, order: order, durations: durations)
    }

    static func dismantleUIView(_ v: FramePlayerUIView, coordinator: ()) {
        v.stop()
    }
}

final class FramePlayerUIView: UIImageView {
    private var frames: [Data] = []
    private var framesID: UUID?
    private var order: [Int] = []
    private var durations: [Double] = []
    /// End time of each position in play order (for finding the frame at a time).
    private var ends: [Double] = []
    private var link: CADisplayLink?
    private var startTime: CFTimeInterval?
    private var shownIndex = -1
    private var cache: [Int: UIImage] = [:]
    private var pending = Set<Int>()
    private let decodeQueue = DispatchQueue(label: "frame-preview-decode", qos: .userInteractive)

    func configure(frames: [Data], id: UUID, order: [Int], durations: [Double]) {
        guard id != framesID || order != self.order || durations != self.durations else { return }
        if id != framesID {
            cache = [:]
            pending = []
            self.frames = frames
            framesID = id
        }
        self.order = order.filter { $0 < frames.count }
        self.durations = durations
        var t = 0.0
        ends = self.order.map { i in
            t += max(i < durations.count ? durations[i] : 0.1, 0.01)
            return t
        }
        startTime = nil
        shownIndex = -1
        // Show the first frame right away.
        if let first = self.order.first {
            if cache[first] == nil, let img = UIImage(data: frames[first]) { cache[first] = img }
            image = cache[first]
            shownIndex = first
        }
        start()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    private func start() {
        guard link == nil, window != nil, !order.isEmpty else { return }
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        startTime = nil
    }

    @objc private func step(_ l: CADisplayLink) {
        guard !order.isEmpty, let total = ends.last, total > 0 else { return }
        if startTime == nil { startTime = l.timestamp }
        let elapsed = (l.timestamp - (startTime ?? l.timestamp)).truncatingRemainder(dividingBy: total)
        // First position whose end is after the elapsed time.
        var lo = 0, hi = ends.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if ends[mid] > elapsed { hi = mid } else { lo = mid + 1 }
        }
        let pos = lo
        let idx = order[pos]
        if idx != shownIndex, let img = cache[idx] {
            image = img
            shownIndex = idx
        }
        prefetch(from: pos)
    }

    /// Decodes the next few frames in play order and drops ones that are far away.
    private func prefetch(from pos: Int) {
        let ahead = 6
        var wanted = Set<Int>()
        for k in 0...ahead {
            let idx = order[(pos + k) % order.count]
            wanted.insert(idx)
            guard cache[idx] == nil, !pending.contains(idx), idx < frames.count else { continue }
            pending.insert(idx)
            let data = frames[idx]
            let id = framesID
            decodeQueue.async { [weak self] in
                let img = UIImage(data: data)?.preparingForDisplay()
                DispatchQueue.main.async {
                    guard let self, self.framesID == id else { return }
                    self.pending.remove(idx)
                    if let img { self.cache[idx] = img }
                }
            }
        }
        if cache.count > 24 {
            for key in cache.keys where !wanted.contains(key) && key != shownIndex {
                cache[key] = nil
            }
        }
    }
}
