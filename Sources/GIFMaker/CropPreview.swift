import SwiftUI

/// Live preview (video, or GIF frames) showing only the cropped area. Drag to move,
/// pinch to zoom.
struct CropPreview: View {
    @ObservedObject var model: EditorModel
    var maxHeight: CGFloat = 360

    @State private var dragStartCenter: CGPoint?
    @State private var zoomStart: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let crop = model.cropRect
            let a = crop.width / max(crop.height, 1)
            let w = min(geo.size.width, maxHeight * a)
            let h = w / max(a, 0.01)
            let s = w / max(crop.width, 1)

            ZStack {
                PlayerLayerView(player: model.player)
                if model.showsFramePreview {
                    FramePlayerView(
                        frames: model.previewFrames,
                        framesID: model.previewFramesID,
                        order: model.previewOrder,
                        durations: model.previewDurations
                    )
                } else if model.isGIF, let still = model.stillImage {
                    // GIF while dragging a handle or while its preview is prepared.
                    Image(uiImage: still).resizable()
                }
            }
                .frame(width: model.videoSize.width * s, height: model.videoSize.height * s)
                .offset(x: -crop.minX * s, y: -crop.minY * s)
                .frame(width: w, height: h, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(scale: s).simultaneously(with: zoomGesture))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: maxHeight)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if model.isPreparingPreview {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Preparing preview…").font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.bottom, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func dragGesture(scale s: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartCenter == nil {
                    let r = model.cropRect
                    dragStartCenter = CGPoint(x: r.midX, y: r.midY)
                }
                guard let start = dragStartCenter, s > 0 else { return }
                model.center = CGPoint(
                    x: start.x - value.translation.width / s,
                    y: start.y - value.translation.height / s
                )
            }
            .onEnded { _ in
                dragStartCenter = nil
                model.normalizeCenter()
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = model.zoom }
                model.zoom = min(max((zoomStart ?? 1) * value.magnification, 1), 4)
            }
            .onEnded { _ in
                zoomStart = nil
                model.normalizeCenter()
            }
    }
}
