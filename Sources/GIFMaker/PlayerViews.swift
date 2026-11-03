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
