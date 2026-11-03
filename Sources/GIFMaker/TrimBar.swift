import SwiftUI

/// Thumbnail strip with draggable start and end handles.
struct TrimBar: View {
    @ObservedObject var model: EditorModel
    private let handleWidth: CGFloat = 16
    private let height: CGFloat = 56
    private let bubbleHeight: CGFloat = 24
    private let bubbleGap: CGFloat = 6
    /// Time of the handle being dragged; nil when not dragging.
    @State private var draggingTime: Double?

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
                .animation(.easeOut(duration: 0.1), value: draggingTime == nil)

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

                // Dim outside the selection
                Color.black.opacity(0.55)
                    .frame(width: max(startX - handleWidth, 0), height: height)
                    .offset(x: handleWidth)
                Color.black.opacity(0.55)
                    .frame(width: max(handleWidth + track - endX, 0), height: height)
                    .offset(x: endX)

                // Selection border
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: max(endX - startX, 0), height: height)
                    .offset(x: startX)

                // Playhead
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height + 8)
                    .offset(x: playX - 1, y: -4)
                    .allowsHitTesting(false)

                handle(systemName: "chevron.compact.left")
                    .offset(x: startX - handleWidth)
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

                handle(systemName: "chevron.compact.right")
                    .offset(x: endX)
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
            }
            .frame(width: geo.size.width, height: height, alignment: .topLeading)
            .coordinateSpace(name: "trim")
            }
        }
        .frame(height: height + bubbleHeight + bubbleGap)
    }

    private var bubbleText: String {
        if let t = draggingTime {
            let m = Int(t) / 60
            return String(format: "%d:%04.1f", m, t - Double(m * 60))
        }
        return String(format: "%.1fs", model.clipLength)
    }

    private func handle(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: height)
            .overlay(Image(systemName: systemName).font(.headline).foregroundStyle(.black))
            .contentShape(Rectangle().inset(by: -10))
    }
}
