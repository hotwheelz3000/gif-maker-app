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
    /// Largest GIF the app makes.
    static let maxBytes = 5 * 1024 * 1024

    static func make(
        _ s: GIFSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> GIFResult {
        var frames: [Data]
        var delays: [Double]
        if let gifURL = s.gifURL {
            (frames, delays) = try readGIFFrames(gifURL, s, progress: progress)
        } else {
            (frames, delays) = try await readVideoFrames(s, progress: progress)
        }
        guard !frames.isEmpty else { throw GIFExportError.noFrames }
        let keepAlpha = s.gifURL != nil   // GIF frames are PNGs (may be transparent)

        var size = s.outputSize
        var (url, bytes) = try write(frames: frames, delays: delays, loopMode: s.loopMode) { p in
            progress(0.7 + 0.15 * p)
        }

        // Keep every GIF at 5 MB or under, using as much of the 5 MB as possible:
        // keep all frames and find the biggest size that fits. Only if it would have to go
        // below 200 wide are frames dropped (every other one, each kept frame showing
        // twice as long so the speed stays), then the size search runs again.
        var note: String?
        if bytes > maxBytes {
            var baseFrames = frames
            var baseDelays = delays
            var hintBytes = bytes          // size of the GIF at full width with these frames
            var anyDropped = false
            var chosen: (url: URL, bytes: Int, size: CGSize)?
            var round = 0
            try? FileManager.default.removeItem(at: url)

            while chosen == nil {
                try Task.checkCancellation()
                let canDrop = baseFrames.count > 2
                chosen = try fitWidth(
                    frames: baseFrames, delays: baseDelays, baseSize: size, startBytes: hintBytes,
                    minWidth: canDrop ? 200 : 16, keepAlpha: keepAlpha, loopMode: s.loopMode
                ) { p in
                    progress(0.85 + 0.15 * min(Double(round) + p, 4) / 4)
                }
                if chosen == nil {
                    guard canDrop else { break }
                    var keptFrames: [Data] = []
                    var keptDelays: [Double] = []
                    for i in stride(from: 0, to: baseFrames.count, by: 2) {
                        keptFrames.append(baseFrames[i])
                        keptDelays.append(baseDelays[i] + (i + 1 < baseFrames.count ? baseDelays[i + 1] : 0))
                    }
                    hintBytes = hintBytes * keptFrames.count / max(baseFrames.count, 1)
                    baseFrames = keptFrames
                    baseDelays = keptDelays
                    anyDropped = true
                    round += 1
                }
            }
            if let chosen {
                url = chosen.url
                bytes = chosen.bytes
                size = chosen.size
                frames = baseFrames
                note = "Shrunk to fit 5 MB · \(Int(size.width))×\(Int(size.height))"
                    + (anyDropped ? " · fewer frames" : "")
            } else {
                throw GIFExportError.writeFailed
            }
        }
        progress(1)

        let frameCount = loopOrder(count: frames.count, loopMode: s.loopMode).count
        return GIFResult(
            url: url, frameCount: frameCount, pixelSize: size, loopMode: s.loopMode,
            bytes: bytes, note: note
        )
    }

    /// Frame order for a loop style.
    static func loopOrder(count: Int, loopMode: LoopMode) -> [Int] {
        switch loopMode {
        case .normal:
            return Array(0..<count)
        case .reverse:
            return Array((0..<count).reversed())
        case .boomerang:
            let back = count > 2 ? Array((1..<(count - 1)).reversed()) : []
            return Array(0..<count) + back
        }
    }

    /// Finds the biggest width (down to minWidth) whose GIF fits in 5 MB, aiming for just
    /// under 5 MB. Each try is made from the full-size frames, so quality isn't lost by
    /// shrinking twice. Returns nil if even minWidth is too big.
    private static func fitWidth(
        frames: [Data], delays: [Double], baseSize: CGSize, startBytes: Int,
        minWidth: CGFloat, keepAlpha: Bool, loopMode: LoopMode,
        progress: (Double) -> Void
    ) throws -> (url: URL, bytes: Int, size: CGSize)? {
        let even: (CGFloat) -> CGFloat = { max(2, ($0 / 2).rounded(.down) * 2) }
        var tooBig = baseSize.width             // smallest width known to be too big
        var best: (url: URL, bytes: Int, size: CGSize)?
        // First guess from the size at full width (file size grows with the pixel count).
        var guess = even(baseSize.width * CGFloat(sqrt(Double(maxBytes) * 0.95 / Double(max(startBytes, 1)))))
        var tries = 0
        while tries < 7 {
            tries += 1
            try Task.checkCancellation()
            guess = min(guess, tooBig - 2)
            if guess < minWidth {
                // Too small: either try exactly minWidth once, or give up.
                if best == nil && tooBig > minWidth { guess = even(minWidth) } else { break }
            }
            let newSize = CGSize(width: guess, height: max(2, even(guess * baseSize.height / baseSize.width)))
            let resized = frames.compactMap { resize($0, to: newSize, keepAlpha: keepAlpha) }
            let (url, bytes) = try write(frames: resized, delays: delays, loopMode: loopMode) { p in
                progress((Double(tries - 1) + p) / 7)
            }
            if bytes <= maxBytes {
                if let old = best { try? FileManager.default.removeItem(at: old.url) }
                best = (url, bytes, newSize)
                // Close enough to 5 MB, or no room left to grow: done.
                if Double(bytes) >= Double(maxBytes) * 0.9 || tooBig - guess <= 8 { break }
                let up = even(guess * CGFloat(sqrt(Double(maxBytes) * 0.95 / Double(bytes))))
                guess = min(max(up, guess + 2), (guess + tooBig) / 2 + 1)
            } else {
                try? FileManager.default.removeItem(at: url)
                tooBig = guess
                if guess <= minWidth { break }
                let down = even(guess * CGFloat(sqrt(Double(maxBytes) * 0.95 / Double(bytes))))
                if let b = best { guess = max(down, (b.size.width + guess) / 2) } else { guess = down }
                if let b = best, tooBig - b.size.width <= 8 { break }
            }
        }
        return best
    }

    /// Writes an endlessly looping GIF to a new temp file; returns it and its size.
    private static func write(
        frames: [Data], delays: [Double], loopMode: LoopMode, progress: (Double) -> Void
    ) throws -> (URL, Int) {
        let order = loopOrder(count: frames.count, loopMode: loopMode)
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
            progress(Double(n + 1) / Double(order.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw GIFExportError.writeFailed }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
        return (outURL, bytes)
    }

    /// Scales one stored frame (JPEG, or PNG when it may be transparent) to a new size.
    private static func resize(_ data: Data, to size: CGSize, keepAlpha: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let scaled = render(
                image, crop: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                videoSize: CGSize(width: image.width, height: image.height),
                outSize: size, keepAlpha: keepAlpha
              )
        else { return nil }
        return keepAlpha ? pngData(scaled) : jpegData(scaled)
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
