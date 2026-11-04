import SwiftUI
import UIKit

/// Live preview (video, or GIF frames) showing only the cropped area. Drag to move,
/// pinch to zoom. While adjusting, centering guides show: an up-and-down line and a
/// side-to-side line through the middle, black, turning yellow when the crop is centered
/// that way. Dragging near center snaps onto it with a light haptic tap.
struct CropPreview: View {
    @ObservedObject var model: EditorModel
    var maxHeight: CGFloat = 360

    @State private var dragStartCenter: CGPoint?
    @State private var zoomStart: CGFloat?
    /// Whether the last drag update was snapped to center (for the haptic tap).
    @State private var snappedX = false
    @State private var snappedY = false

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
                .overlay { guides(width: w, height: h) }
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
                model.showGuides(hideAfter: nil)
                var x = start.x - value.translation.width / s
                var y = start.y - value.translation.height / s
                // Snap to center when within about 8 points on screen.
                let snap = 8 / s
                let cx = model.videoSize.width / 2, cy = model.videoSize.height / 2
                let nowX = model.canMoveX && abs(x - cx) < snap
                let nowY = model.canMoveY && abs(y - cy) < snap
                if nowX { x = cx }
                if nowY { y = cy }
                if (nowX && !snappedX) || (nowY && !snappedY) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                snappedX = nowX
                snappedY = nowY
                model.center = CGPoint(x: x, y: y)
            }
            .onEnded { _ in
                dragStartCenter = nil
                snappedX = false
                snappedY = false
                model.normalizeCenter()
                model.showGuides()
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = model.zoom }
                model.zoom = min(max((zoomStart ?? 1) * value.magnification, 1), 4)
                model.showGuides(hideAfter: nil)
            }
            .onEnded { _ in
                zoomStart = nil
                model.normalizeCenter()
                model.showGuides()
            }
    }

    /// Centering guides: black lines through the middle, yellow when centered that way.
    /// Each line only shows when the crop can move along it.
    @ViewBuilder
    private func guides(width w: CGFloat, height h: CGFloat) -> some View {
        if model.guidesVisible {
            ZStack {
                if model.canMoveX {
                    Rectangle()
                        .fill(model.isCenteredX ? Color.yellow : Color.black)
                        .frame(width: model.isCenteredX ? 2 : 1.5, height: h)
                }
                if model.canMoveY {
                    Rectangle()
                        .fill(model.isCenteredY ? Color.yellow : Color.black)
                        .frame(width: w, height: model.isCenteredY ? 2 : 1.5)
                }
            }
            .frame(width: w, height: h)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
