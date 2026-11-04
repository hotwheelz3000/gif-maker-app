import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GIFSettings: Sendable {
    let videoURL: URL
    let start: Double
    let end: Double
    let crop: CGRect        // in video pixels, top-left origin
    let videoSize: CGSize
    let outputSize: CGSize
    let fps: Int
    let speed: Double
    let loopMode: LoopMode
    /// Set when editing a GIF: frames come straight from this file. fps 0 = Original.
    let gifURL: URL?
}


enum GIFExportError: LocalizedError {
    case noFrames
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noFrames: return "Couldn't read any frames from this clip."
        case .writeFailed: return "Couldn't write the GIF file."
        }
    }
}

enum GIFExporter {
    /// Makes the GIF: reads frames from the trimmed range (from the video, or straight
    /// from the GIF being edited), crops and scales them, puts them in loop order and
    /// writes an endlessly looping GIF. Progress goes 0...1 (reading is the first 70%).
    static func make(
        _ s: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GIFResult {
        let frames: [Data]
        let delays: [Double]
        if let gifURL = s.gifURL {
            (frames, delays) = try readGIFFrames(gifURL, s, progress: progress)
        } else {
            (frames, delays) = try await readVideoFrames(s, progress: progress)
        }
        guard !frames.isEmpty else { throw GIFExportError.noFrames }

        // Loop order.
        let order: [Int]
        switch s.loopMode {
        case .normal:
            order = Array(frames.indices)
        case .reverse:
            order = Array(frames.indices.reversed())
        case .boomerang:
            let back = frames.count > 2 ? Array((1..<(frames.count - 1)).reversed()) : []
            order = Array(frames.indices) + back
        }

        // Write the GIF.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIF-\(UUID().uuidString)")
            .appendingPathExtension("gif")
        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, UTType.gif.identifier as CFString, order.count, nil
        ) else { throw GIFExportError.writeFailed }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        for (n, index) in order.enumerated() {
            try Task.checkCancellation()
            // GIF players treat delays under 0.02 s as slow frames, so don't go below.
            let delay = max(delays[index], 0.02)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ]
            ]
            if let src = CGImageSourceCreateWithData(frames[index] as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
            }
            progress(0.7 + 0.3 * Double(n + 1) / Double(order.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw GIFExportError.writeFailed }

        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        return GIFResult(url: outURL, frameCount: order.count, pixelSize: s.outputSize, loopMode: s.loopMode, bytes: bytes)
    }

    /// Video: frames at an even rate across the range, kept as JPEGs (in time order).
    private static func readVideoFrames(
        _ s: GIFSettings, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ([Data], [Double]) {
        let fps = s.fps > 0 ? s.fps : 15
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: s.videoURL))
        gen.appliesPreferredTrackTransform = true

        // Source time step per output frame: faster speed skips more source time.
        let step = s.speed / Double(fps)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance

        // Times use a fixed 600 timescale so each result can be matched back
        // to its slot, whatever order the generator returns them in.
        var times: [CMTime] = []
        var slotForTime: [Int64: Int] = [:]
        var t = s.start
        while t < s.end - 0.0001 {
            let time = CMTime(value: Int64((t * 600).rounded()), timescale: 600)
            if slotForTime[time.value] == nil {
                slotForTime[time.value] = times.count
                times.append(time)
            }
            t += step
        }
        guard !times.isEmpty else { throw GIFExportError.noFrames }

        var slots = [Data?](repeating: nil, count: times.count)
        var done = 0
        for await item in gen.images(for: times) {
            try Task.checkCancellation()
            done += 1
            let key = CMTimeConvertScale(item.requestedTime, timescale: 600, method: .roundHalfAwayFromZero).value
            if let slot = slotForTime[key],
               let cg = try? item.image,
               let rendered = render(cg, crop: s.crop, videoSize: s.videoSize, outSize: s.outputSize),
               let jpeg = jpegData(rendered) {
                slots[slot] = jpeg
            }
            progress(0.7 * Double(done) / Double(times.count))
        }
        let frames = slots.compactMap { $0 }
        return (frames, Array(repeating: 1.0 / Double(fps), count: frames.count))
    }

    /// GIF: the GIF's own frames (or frames at an even rate), kept as PNGs so nothing
    /// is lost and transparency stays.
    private static func readGIFFrames(
        _ gifURL: URL, _ s: GIFSettings, progress: @escaping @Sendable (Double) -> Void
    ) throws -> ([Data], [Double]) {
        guard let gif = GIFSource(url: gifURL) else { throw GIFExportError.noFrames }
        let plan = gif.plan(start: s.start, end: s.end, speed: s.speed, fps: s.fps)
        var made: [Int: Data] = [:]
        var frames: [Data] = []
        var delays: [Double] = []
        for (n, step) in plan.enumerated() {
            try Task.checkCancellation()
            var data = made[step.index]
            if data == nil,
               let cg = gif.image(at: step.index),
               let rendered = render(cg, crop: s.crop, videoSize: s.videoSize, outSize: s.outputSize, keepAlpha: true) {
                data = pngData(rendered)
                made[step.index] = data
            }
            if let data {
                frames.append(data)
                delays.append(step.duration)
            }
            progress(0.7 * Double(n + 1) / Double(plan.count))
        }
        return (frames, delays)
    }

    /// Crops a frame (crop is in video-pixel coordinates) and scales it to outSize.
    static func render(
        _ src: CGImage, crop: CGRect, videoSize: CGSize, outSize: CGSize, keepAlpha: Bool = false
    ) -> CGImage? {
        guard videoSize.width > 0, videoSize.height > 0 else { return nil }
        let sx = CGFloat(src.width) / videoSize.width
        let sy = CGFloat(src.height) / videoSize.height
        let bounds = CGRect(x: 0, y: 0, width: src.width, height: src.height)
        let r = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
            .integral
            .intersection(bounds)
        guard !r.isEmpty, let cropped = src.cropping(to: r) else { return nil }

        let w = Int(outSize.width)
        let h = Int(outSize.height)
        guard w > 0, h > 0,
              let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: (keepAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func jpegData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
