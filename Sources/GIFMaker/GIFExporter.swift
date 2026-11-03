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
    /// Reads frames from the trimmed range, crops and scales them, then writes
    /// an endlessly looping GIF. Progress goes 0...1 (reading is the first 70%).
    static func make(
        _ s: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GIFResult {
        let asset = AVURLAsset(url: s.videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true

        // Source time step per output frame: faster speed skips more source time.
        let step = s.speed / Double(max(s.fps, 1))
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

        // 1. Read frames; keep them as small JPEGs (in time order) to save memory.
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
        guard !frames.isEmpty else { throw GIFExportError.noFrames }

        // 2. Put frames in loop order.
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

        // 3. Write the GIF.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GIF-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension("gif")
        try? FileManager.default.removeItem(at: outURL)
        guard let dest = CGImageDestinationCreateWithURL(
            outURL as CFURL, UTType.gif.identifier as CFString, order.count, nil
        ) else { throw GIFExportError.writeFailed }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let delay = 1.0 / Double(max(s.fps, 1))
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ]
        ]

        for (n, index) in order.enumerated() {
            try Task.checkCancellation()
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

    /// Crops a frame (crop is in video-pixel coordinates) and scales it to outSize.
    static func render(_ src: CGImage, crop: CGRect, videoSize: CGSize, outSize: CGSize) -> CGImage? {
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
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
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
