import SwiftUI

/// Thumbnail strip with draggable start and end handles.
/// - Handles have 44-point grab areas.
/// - Dragging inside the selection slides the whole window (keeps its length).
/// - VoiceOver: each handle and the selection are adjustable (swipe up / down).
struct TrimBar: View {
    @ObservedObject var model: EditorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let handleWidth: CGFloat = 16   // visible width
    private let hitWidth: CGFloat = 44      // touch width
    private let height: CGFloat = 56
    private let bubbleHeight: CGFloat = 24
    private let bubbleGap: CGFloat = 6

    /// Time shown in the bubble while a handle is dragged; nil otherwise.
    @State private var draggingTime: Double?
    /// Start time and finger x when a whole-selection drag began.
    @State private var moveOrigin: (start: Double, x: CGFloat)?

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.width - handleWidth * 2, 1)
            let d = max(model.duration, 0.01)
            let startX = handleWidth + CGFloat(model.start / d) * track
            let endX = handleWidth + CGFloat(model.end / d) * track
            let playX = handleWidth + CGFloat(min(max(model.currentTime, 0), d) / d) * track

            VStack(alignment: .leading, spacing: bubbleGap) {
                // Bubble above the selection: clip length, or the dragged handle's time.
                Text(bubbleText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .frame(height: bubbleHeight)
                    .background(Capsule().fill(Color.yellow))
                    .fixedSize()
                    .position(
                        x: min(max((startX + endX) / 2, 40), geo.size.width - 40),
                        y: bubbleHeight / 2
                    )
                    .frame(width: geo.size.width, height: bubbleHeight)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: draggingTime == nil)
                    .accessibilityHidden(true)

                ZStack(alignment: .topLeading) {
                    // Thumbnails
                    HStack(spacing: 0) {
                        ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, img in
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: track / CGFloat(max(model.thumbnails.count, 1)), height: height)
                                .clipped()
                        }
                    }
                    .frame(width: track, height: height, alignment: .leading)
                    .background(Color.gray.opacity(0.3))
                    .offset(x: handleWidth)
                    .accessibilityHidden(true)

                    // Dim outside the selection
                    Color.black.opacity(0.55)
                        .frame(width: max(startX - handleWidth, 0), height: height)
                        .offset(x: handleWidth)
                        .accessibilityHidden(true)
                    Color.black.opacity(0.55)
                        .frame(width: max(handleWidth + track - endX, 0), height: height)
                        .offset(x: endX)
                        .accessibilityHidden(true)

                    // Selection: border, and a drag area that moves the whole window.
                    Rectangle()
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: max(endX - startX, 0), height: height)
                        .contentShape(Rectangle())
                        .offset(x: startX)
                        .gesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named("trim"))
                                .onChanged { v in
                                    if moveOrigin == nil { moveOrigin = (model.start, v.startLocation.x) }
                                    guard let o = moveOrigin else { return }
                                    let dt = Double((v.location.x - o.x) / track) * d
                                    model.moveSelection(start: o.start + dt)
                                    draggingTime = model.start
                                    model.scrub(to: model.start)
                                }
                                .onEnded { _ in
                                    moveOrigin = nil
                                    draggingTime = nil
                                    model.endScrub()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Selection")
                        .accessibilityValue("\(timeString(model.start)) to \(timeString(model.end)), \(String(format: "%.1f", model.clipLength)) seconds")
                        .accessibilityHint("Swipe up or down to move the selection by half a second.")
                        .accessibilityAdjustableAction { dir in
                            let step = dir == .increment ? 0.5 : -0.5
                            model.moveSelection(start: model.start + step)
                            model.restartLoop()
                        }

                    // Playhead
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: height + 8)
                        .offset(x: playX - 1, y: -4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    handle(systemName: "chevron.compact.left")
                        // Visible part sits just left of the selection; grab area is centered on it.
                        .offset(x: startX - handleWidth / 2 - hitWidth / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                                .onChanged { v in
                                    let t = Double((v.location.x - handleWidth) / track) * d
                                    model.setStart(t)
                                    draggingTime = model.start
                                    model.scrub(to: model.start)
                                }
                                .onEnded { _ in
                                    draggingTime = nil
                                    model.endScrub()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Start")
                        .accessibilityValue(timeString(model.start))
                        .accessibilityHint("Swipe up or down to change by a tenth of a second.")
                        .accessibilityAdjustableAction { dir in
                            model.nudgeStart(dir == .increment ? 0.1 : -0.1)
                        }

                    handle(systemName: "chevron.compact.right")
                        .offset(x: endX + handleWidth / 2 - hitWidth / 2)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                                .onChanged { v in
                                    let t = Double((v.location.x - handleWidth) / track) * d
                                    model.setEnd(t)
                                    draggingTime = model.end
                                    model.scrub(to: model.end)
                                }
                                .onEnded { _ in
                                    draggingTime = nil
                                    model.endScrub()
                                }
                        )
                        .accessibilityElement()
                        .accessibilityLabel("End")
                        .accessibilityValue(timeString(model.end))
                        .accessibilityHint("Swipe up or down to change by a tenth of a second.")
                        .accessibilityAdjustableAction { dir in
                            model.nudgeEnd(dir == .increment ? 0.1 : -0.1)
                        }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
                .coordinateSpace(name: "trim")
            }
        }
        .frame(height: height + bubbleHeight + bubbleGap)
    }

    private var bubbleText: String {
        if let t = draggingTime { return timeString(t) }
        return String(format: "%.1fs", model.clipLength)
    }

    /// A 16-point yellow handle inside a 44-point invisible grab area.
    private func handle(systemName: String) -> some View {
        ZStack {
            Color.clear
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.yellow)
                .frame(width: handleWidth, height: height)
                .overlay(Image(systemName: systemName).font(.headline).foregroundStyle(.black))
        }
        .frame(width: hitWidth, height: height)
        .contentShape(Rectangle())
    }
}

func timeString(_ s: Double) -> String {
    let m = Int(max(s, 0)) / 60
    return String(format: "%d:%04.1f", m, max(s, 0) - Double(m * 60))
}
