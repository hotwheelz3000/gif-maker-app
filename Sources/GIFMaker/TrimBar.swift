import SwiftUI
import UIKit

/// Trim strip with start and end handles.
/// - Shows at most 30 seconds at once (zoomed in around the selection on long videos);
///   a thin overview line underneath shows where that window sits in the whole video.
/// - Handles move by how far you drag (no jump), measured against the screen rather
///   than the moving handle (measuring against the handle made it wobble), have
///   44-point grab areas, and take priority over page scrolling.
/// - Dragging inside the selection slides the whole window (keeps its length).
/// - A light tap of haptics when the clip hits its shortest or longest length.
/// - VoiceOver: each handle and the selection are adjustable (swipe up / down).
struct TrimBar: View {
    @ObservedObject var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let handleWidth: CGFloat = 24   // visible width
    private let hitWidth: CGFloat = 44      // touch width
    private let height: CGFloat = 64
    private let bubbleHeight: CGFloat = 24
    private let bubbleGap: CGFloat = 6
    private let overviewHeight: CGFloat = 4
    private let overviewGap: CGFloat = 10

    /// Time shown in the bubble while dragging; nil otherwise.
    @State private var draggingTime: Double?
    /// Value (start or end time) when the current drag began.
    @State private var dragOrigin: Double?
    /// Whether the clip was at a length limit on the last drag update (for haptics).
    @State private var atLimit = false

    private var showsOverview: Bool { model.windowLength < model.duration - 0.01 }

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.width - handleWidth * 2, 1)
            let ws = model.windowStart
            let wl = max(model.windowLength, 0.01)
            let x: (Double) -> CGFloat = { t in handleWidth + CGFloat((t - ws) / wl) * track }
            let startX = x(model.start)
            let endX = x(model.end)

            VStack(alignment: .leading, spacing: bubbleGap) {
                bubble(centerX: (startX + endX) / 2, width: geo.size.width)

                ZStack(alignment: .topLeading) {
                    ThumbnailStrip(
                        thumbnails: model.thumbnails,
                        version: model.thumbnailsVersion,
                        duration: model.duration,
                        windowStart: model.windowStart,
                        windowLength: model.windowLength,
                        track: track,
                        height: height,
                        error: model.thumbnailError,
                        loading: model.isLoadingThumbnails
                    )
                    .equatable()
                    .offset(x: handleWidth)

                    // Dim outside the selection
                    Color.black.opacity(0.55)
                        .frame(width: max(min(startX, handleWidth + track) - handleWidth, 0), height: height)
                        .offset(x: handleWidth)
                        .accessibilityHidden(true)
                    Color.black.opacity(0.55)
                        .frame(width: max(handleWidth + track - max(endX, handleWidth), 0), height: height)
                        .offset(x: max(endX, handleWidth))
                        .accessibilityHidden(true)

                    selection(width: max(endX - startX, 0), track: track, wl: wl)
                        .offset(x: startX)

                    Playhead(
                        clock: model.clock,
                        windowStart: ws,
                        windowLength: wl,
                        track: track,
                        inset: handleWidth,
                        height: height
                    )

                    startHandle(track: track, wl: wl)
                        .offset(x: startX - handleWidth / 2 - hitWidth / 2)
                    endHandle(track: track, wl: wl)
                        .offset(x: endX + handleWidth / 2 - hitWidth / 2)
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)

                if showsOverview {
                    overview(track: track)
                        .padding(.top, overviewGap - bubbleGap)
                        .offset(x: handleWidth)
                }
            }
        }
        .frame(height: height + bubbleHeight + bubbleGap + (showsOverview ? overviewHeight + overviewGap : 0))
    }

    // MARK: Pieces

    private func bubble(centerX: CGFloat, width: CGFloat) -> some View {
        Text(bubbleText)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.black)
            .padding(.horizontal, 8)
            .frame(height: bubbleHeight)
            .background(Capsule().fill(Color.yellow))
            .fixedSize()
            .position(x: min(max(centerX, 40), width - 40), y: bubbleHeight / 2)
            .frame(width: width, height: bubbleHeight)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: draggingTime == nil)
            .accessibilityHidden(true)
    }

    /// Thin line for the whole video: grey = all, light = visible window, yellow = selection.
    private func overview(track: CGFloat) -> some View {
        let d = max(model.duration, 0.01)
        let px: (Double) -> CGFloat = { t in CGFloat(t / d) * track }
        return ZStack(alignment: .leading) {
            Capsule().fill(Color(white: 0.25)).frame(width: track)
            Capsule().fill(Color(white: 0.55))
                .frame(width: max(px(model.windowLength), 4))
                .offset(x: px(model.windowStart))
            Capsule().fill(Color.yellow)
                .frame(width: max(px(model.clipLength), 3))
                .offset(x: px(model.start))
        }
        .frame(width: track, height: overviewHeight, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func selection(width: CGFloat, track: CGFloat, wl: Double) -> some View {
        Rectangle()
            .stroke(Color.yellow, lineWidth: 3)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { v in
                        if dragOrigin == nil { dragOrigin = model.start }
                        guard let origin = dragOrigin else { return }
                        let dt = Double(v.translation.width / track) * wl
                        // Stay inside the visible window while dragging; it recenters after.
                        let lo = model.windowStart
                        let hi = model.windowStart + model.windowLength - model.clipLength
                        model.moveSelection(start: min(max(origin + dt, lo), max(lo, hi)))
                        draggingTime = model.start
                        model.scrub(to: model.start)
                    }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel("Selection")
            .accessibilityValue("\(timeString(model.start)) to \(timeString(model.end)), \(String(format: "%.1f", model.clipLength)) seconds")
            .accessibilityHint("Swipe up or down to move the selection by half a second.")
            .accessibilityAdjustableAction { dir in
                model.moveSelection(start: model.start + (dir == .increment ? 0.5 : -0.5))
                model.keepSelectionVisible()
                model.restartLoop()
            }
    }

    private func startHandle(track: CGFloat, wl: Double) -> some View {
        handle(systemName: "chevron.compact.left")
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragOrigin == nil { dragOrigin = model.start }
                        guard let origin = dragOrigin else { return }
                        let t = origin + Double(v.translation.width / track) * wl
                        model.setStart(max(t, model.windowStart))
                        draggingTime = model.start
                        checkLimit()
                        model.scrub(to: model.start)
                    }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel("Start")
            .accessibilityValue(timeString(model.start))
            .accessibilityHint("Swipe up or down to change by a tenth of a second.")
            .accessibilityAdjustableAction { dir in
                model.nudgeStart(dir == .increment ? 0.1 : -0.1)
            }
    }

    private func endHandle(track: CGFloat, wl: Double) -> some View {
        handle(systemName: "chevron.compact.right")
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { v in
                        if dragOrigin == nil { dragOrigin = model.end }
                        guard let origin = dragOrigin else { return }
                        let t = origin + Double(v.translation.width / track) * wl
                        model.setEnd(min(t, model.windowStart + model.windowLength))
                        draggingTime = model.end
                        checkLimit()
                        model.scrub(to: model.end)
                    }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityElement()
            .accessibilityLabel("End")
            .accessibilityValue(timeString(model.end))
            .accessibilityHint("Swipe up or down to change by a tenth of a second.")
            .accessibilityAdjustableAction { dir in
                model.nudgeEnd(dir == .increment ? 0.1 : -0.1)
            }
    }

    private func endDrag() {
        dragOrigin = nil
        draggingTime = nil
        atLimit = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            model.recenterWindow()
        }
        model.endScrub()
    }

    /// Light haptic tap when the clip first reaches its shortest or longest length.
    private func checkLimit() {
        let len = model.clipLength
        let limited = len >= EditorModel.maxClip - 0.001 || len <= EditorModel.minClip + 0.001
        if limited && !atLimit {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        atLimit = limited
    }

    private var bubbleText: String {
        if let t = draggingTime { return timeString(t) }
        return String(format: "%.1fs", model.clipLength)
    }

    /// A 24-point yellow handle inside a 44-point invisible grab area.
    private func handle(systemName: String) -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow)
                .frame(width: handleWidth, height: height)
                .overlay(Image(systemName: systemName).font(.title3.weight(.bold)).foregroundStyle(.black))
        }
        .frame(width: hitWidth, height: height)
        .contentShape(Rectangle())
    }
}

func timeString(_ s: Double) -> String {
    let m = Int(max(s, 0)) / 60
    return String(format: "%d:%04.1f", m, max(s, 0) - Double(m * 60))
}

/// The playhead line. Watches only the playback clock, so it can move 30 times a
/// second without redrawing the rest of the trim bar.
private struct Playhead: View {
    @ObservedObject var clock: PlaybackClock
    let windowStart: Double
    let windowLength: Double
    let track: CGFloat
    let inset: CGFloat
    let height: CGFloat

    var body: some View {
        let x = inset + CGFloat((clock.time - windowStart) / max(windowLength, 0.01)) * track
        if x >= inset && x <= inset + track {
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: height + 8)
                .offset(x: x - 1, y: -4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// Previews for the whole video, laid out wide and shifted so only the visible window
/// shows. Equatable, so it only redraws when its pictures or the window change (not on
/// every handle movement).
private struct ThumbnailStrip: View, Equatable {
    let thumbnails: [UIImage?]
    let version: Int
    let duration: Double
    let windowStart: Double
    let windowLength: Double
    let track: CGFloat
    let height: CGFloat
    let error: String?
    let loading: Bool

    static func == (a: ThumbnailStrip, b: ThumbnailStrip) -> Bool {
        a.version == b.version && a.duration == b.duration && a.windowStart == b.windowStart
            && a.windowLength == b.windowLength && a.track == b.track && a.height == b.height
            && a.error == b.error && a.loading == b.loading
    }

    var body: some View {
        let d = max(duration, 0.01)
        let fullWidth = track * CGFloat(d / max(windowLength, 0.01))
        let count = max(thumbnails.count, 1)
        let slotWidth = fullWidth / CGFloat(count)
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                ZStack {
                    Color(white: 0.18)
                    if i < thumbnails.count, let img = thumbnails[i] {
                        Image(uiImage: img).resizable().scaledToFill()
                    }
                }
                .frame(width: slotWidth, height: height)
                .clipped()
            }
        }
        .drawingGroup()
        .frame(width: fullWidth, height: height, alignment: .leading)
        .offset(x: -fullWidth * CGFloat(windowStart / d))
        .frame(width: track, height: height, alignment: .leading)
        .clipped()
        .background(Color.gray.opacity(0.3))
        .overlay {
            if let error {
                Text(error)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
            } else if loading && thumbnails.allSatisfy({ $0 == nil }) {
                ProgressView().tint(.white)
            }
        }
        .accessibilityHidden(true)
    }
}
