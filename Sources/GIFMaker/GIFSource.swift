import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// An animated GIF opened for editing. Frames are read straight from the file
/// (no video conversion), so editing a GIF doesn't lose quality or transparency.
final class GIFSource: @unchecked Sendable {
    let url: URL
    private let source: CGImageSource
    let count: Int
    /// How long each frame shows, in seconds.
    let delays: [Double]
    /// When each frame starts, in seconds.
    let starts: [Double]
    let duration: Double
    let size: CGSize

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src),
              (type as String) == UTType.gif.identifier
        else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }

        var delays: [Double] = []
        var starts: [Double] = []
        var t = 0.0
        for i in 0..<n {
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            var d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            // Browsers treat tiny delays as 0.1 s; do the same so timing matches.
            if d < 0.02 { d = 0.1 }
            starts.append(t)
            delays.append(d)
            t += d
        }
        let props0 = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props0?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props0?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { return nil }

        self.url = url
        self.source = src
        self.count = n
        self.delays = delays
        self.starts = starts
        self.duration = t
        self.size = CGSize(width: w, height: h)
    }

    /// The frame showing at time t.
    func frameIndex(at t: Double) -> Int {
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= t + 0.0001 { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Full frame at its original size.
    func image(at i: Int) -> CGImage? {
        CGImageSourceCreateImageAtIndex(source, min(max(i, 0), count - 1), nil)
    }

    /// Which frames to use for the range, and how long each shows.
    /// fps 0 means Original: the GIF's own frames and timing (divided by speed).
    /// Otherwise frames are picked at an even rate, like a video.
    func plan(start: Double, end: Double, speed: Double, fps: Int) -> [(index: Int, duration: Double)] {
        var result: [(Int, Double)] = []
        if fps <= 0 {
            for i in 0..<count {
                let s = starts[i], e = s + delays[i]
                guard e > start + 0.0001, s < end - 0.0001 else { continue }
                // Trim the first and last frames to the selection.
                let shown = min(e, end) - max(s, start)
                result.append((i, max(shown, 0.01) / speed))
            }
            if result.isEmpty { result.append((frameIndex(at: start), 0.1 / speed)) }
        } else {
            let step = speed / Double(fps)
            var t = start
            while t < end - 0.0001 {
                result.append((frameIndex(at: t), 1.0 / Double(fps)))
                t += step
            }
            if result.isEmpty { result.append((frameIndex(at: start), 1.0 / Double(fps))) }
        }
        return result
    }
}

/// A GIF picked from Photos, copied into the app's temp folder.
struct GIFFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .gif) { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("gif")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return GIFFile(url: dest)
        }
    }
}
