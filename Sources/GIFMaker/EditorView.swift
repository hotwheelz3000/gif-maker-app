import SwiftUI

/// Creator-style editor: big preview on top, one tool's controls below,
/// a tool bar along the bottom, and Next in the top-right corner.
struct EditorView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case trim = "Trim"
        case crop = "Crop"
        case loop = "Loop"
        case quality = "Quality"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .trim: return "scissors"
            case .crop: return "crop"
            case .loop: return "repeat"
            case .quality: return "slider.horizontal.3"
            }
        }
    }

    @StateObject private var model: EditorModel
    @State private var tool: Tool = .trim

    init(url: URL, isGIF: Bool = false) {
        _model = StateObject(wrappedValue: EditorModel(url: url, isGIF: isGIF))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let error = model.loadError {
                ContentUnavailableView("Can't Open Video", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !model.isReady {
                ProgressView("Opening video...").tint(.white)
            } else {
                editor
            }
        }
        .navigationTitle("")
        .noSwipeBack()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            // No visible title; VoiceOver hears the current section (Trim, Crop, Loop, Quality).
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(tool.rawValue)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.makeGIF()
                } label: {
                    Text("Next")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 36)
                        .background(Theme.gradient, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!model.isReady || model.isExporting || model.clipLength < EditorModel.minClip)
                .opacity(model.isReady ? 1 : 0.4)
                .accessibilityLabel("Next, make GIF")
            }
        }
        .task { await model.load() }
        .onAppear { if model.isReady && !model.isExporting { model.restartLoop() } }
        .onDisappear { model.pause() }
        .navigationDestination(item: $model.result) { result in
            ResultView(result: result)
        }
    }

    // MARK: Layout

    private var editor: some View {
        VStack(spacing: 0) {
            CropPreview(model: model, maxHeight: 360)
                .accessibilityElement()
                .accessibilityLabel("Video preview, crop \(model.aspect.rawValue)")
                .accessibilityHint("Use the Crop tool's buttons to zoom or move the crop.")

            Rectangle().fill(Theme.surface).frame(height: 1).accessibilityHidden(true)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tool {
                    case .trim: trimPanel
                    case .crop: cropPanel
                    case .loop: loopPanel
                    case .quality: qualityPanel
                    }
                    if let err = model.exportError {
                        Text(err).font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            toolBar
        }
        .overlay {
            if model.isExporting { exportOverlay }
        }
    }

    private var toolBar: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases) { t in
                Button {
                    tool = t
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(tool == t ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.secondaryText))
                        Text(t.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(tool == t ? .white : Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(t.rawValue) tool")
                .accessibilityAddTraits(tool == t ? .isSelected : [])
            }
        }
        .padding(.top, 6)
        .background(Theme.background)
        .overlay(alignment: .top) { Rectangle().fill(Theme.surface).frame(height: 1) }
    }

    // MARK: Panels

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TrimBar(model: model)
            HStack {
                Text("\(timeString(model.start)) – \(timeString(model.end))")
                Spacer()
                Text(String(format: "max %.0fs", EditorModel.maxClip))
                    .foregroundStyle(Theme.secondaryText)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .accessibilityHidden(true)

            nudgeRow(title: "Start", plus: { model.nudgeStart(0.1) }, minus: { model.nudgeStart(-0.1) })
            nudgeRow(title: "End", plus: { model.nudgeEnd(0.1) }, minus: { model.nudgeEnd(-0.1) })
        }
    }

    private var cropPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropAspect.allCases) { a in
                        Button(a.rawValue) { model.aspect = a }
                            .buttonStyle(ChipButtonStyle(selected: model.aspect == a))
                            .accessibilityLabel("Crop \(a.rawValue)")
                            .accessibilityAddTraits(model.aspect == a ? .isSelected : [])
                    }
                }
            }

            HStack(spacing: 8) {
                rowLabel("Zoom")
                iconButton("minus", label: "Zoom out") { model.zoom(by: 1 / 1.25) }
                    .disabled(model.zoom <= 1.001)
                iconButton("plus", label: "Zoom in") { model.zoom(by: 1.25) }
                    .disabled(model.zoom >= 3.999)
                Button("Reset") { model.resetCrop() }
                    .buttonStyle(ChipButtonStyle())
                    .accessibilityLabel("Reset crop")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                rowLabel("Move")
                iconButton("arrow.left", label: "Move crop left") { model.moveCrop(dx: -1, dy: 0) }
                    .disabled(!model.canMoveLeft)
                iconButton("arrow.up", label: "Move crop up") { model.moveCrop(dx: 0, dy: -1) }
                    .disabled(!model.canMoveUp)
                iconButton("arrow.down", label: "Move crop down") { model.moveCrop(dx: 0, dy: 1) }
                    .disabled(!model.canMoveDown)
                iconButton("arrow.right", label: "Move crop right") { model.moveCrop(dx: 1, dy: 0) }
                    .disabled(!model.canMoveRight)
                Spacer(minLength: 0)
            }
            Text("Move shifts the part of the video you keep. It works once you zoom in or pick a shape that cuts off part of the video. You can also drag and pinch the video.")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var loopPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("Loop style")
            ChipPicker(
                title: "Loop",
                options: LoopMode.allCases.map { ($0, $0.rawValue) },
                selection: $model.loopMode
            )
            if !model.previewShowsLoopMode {
                Text("This video can't play backwards in the preview, but the GIF will be \(model.loopMode.rawValue.lowercased()).")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            panelTitle("Speed")
            ChipPicker(
                title: "Speed",
                options: [(0.5, "0.5x"), (1.0, "1x"), (1.5, "1.5x"), (2.0, "2x")],
                selection: $model.speed
            )
        }
    }

    private var qualityPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("Size")
            panelNote(model.isGIF
                ? "How wide the GIF is in pixels. Original keeps the GIF's own size, so nothing is lost."
                : "How wide the GIF is in pixels. Bigger looks sharper but makes a larger file.")
            ChipPicker(
                title: "Width",
                options: (model.isGIF ? [(0, "Original")] : []) + [(320, "320"), (480, "480"), (720, "720")],
                selection: $model.width
            )
            panelTitle("Frame rate")
            panelNote(model.isGIF
                ? "Frames per second. Original keeps the GIF's own frames and timing."
                : "Frames per second. Higher is smoother, lower makes a smaller file.")
            ChipPicker(
                title: "Frame rate",
                options: (model.isGIF ? [(0, "Original")] : [])
                    + [(10, "10"), (14, "14"), (15, "15"), (24, "24")].map { ($0.0, "\($0.1) fps") },
                selection: $model.fps
            )
            panelNote("GIFs are kept at 5 MB or under; big sizes or long clips may be shrunk.")
            let size = model.outputSize
            Text("\(Int(size.width))×\(Int(size.height)) · about \(model.estimatedFrames) frames")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel("Output \(Int(size.width)) by \(Int(size.height)), about \(model.estimatedFrames) frames")
        }
    }

    private var exportOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: model.progress)
                    .tint(Theme.pink)
                    .frame(width: 220)
                    .accessibilityLabel("Making GIF")
                Text("Making your GIF... \(Int(model.progress * 100))%")
                    .font(.headline.weight(.bold))
                Button("Cancel") { model.cancelExport() }
                    .buttonStyle(PillButtonStyle(prominent: false))
            }
            .padding(28)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    // MARK: Pieces

    private func panelTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.isHeader)
    }

    private func panelNote(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.bold))
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 52, alignment: .leading)
            .accessibilityHidden(true)
    }

    /// "Start ........ [+]  [−]" — 44-point buttons that move a handle by 0.1 s.
    /// Hold one down to keep moving (repeats, speeding up the longer it's held).
    private func nudgeRow(title: String, plus: @escaping () -> Void, minus: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Text(title).font(.subheadline.weight(.bold)).accessibilityHidden(true)
            Spacer()
            iconButton("plus", label: "\(title) later by a tenth of a second", action: plus)
                .buttonRepeatBehavior(.enabled)
            iconButton("minus", label: "\(title) earlier by a tenth of a second", action: minus)
                .buttonRepeatBehavior(.enabled)
        }
    }

    /// Round dark icon button, at least 44 × 44 points, with a VoiceOver label.
    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.body.weight(.bold))
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityLabel(label)
    }
}
