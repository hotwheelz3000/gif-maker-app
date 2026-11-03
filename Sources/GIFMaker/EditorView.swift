import SwiftUI

struct EditorView: View {
    @StateObject private var model: EditorModel

    init(url: URL) {
        _model = StateObject(wrappedValue: EditorModel(url: url))
    }

    var body: some View {
        Group {
            if let error = model.loadError {
                ContentUnavailableView("Can't Open Video", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !model.isReady {
                ProgressView("Opening video...")
            } else {
                editor
            }
        }
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onAppear { if model.isReady && !model.isExporting { model.restartLoop() } }
        .onDisappear { model.pause() }
        .navigationDestination(item: $model.result) { result in
            ResultView(result: result)
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            CropPreview(model: model)
                .accessibilityElement()
                .accessibilityLabel("Video preview, crop \(model.aspect.rawValue)")
                .accessibilityHint("Use the crop buttons below to zoom or move the crop.")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Trim") {
                        TrimBar(model: model)
                        HStack {
                            Text("\(timeString(model.start)) – \(timeString(model.end))")
                            Spacer()
                            Text(String(format: "%.1fs (max %.0fs)", model.clipLength, EditorModel.maxClip))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.monospacedDigit())
                        .accessibilityHidden(true)

                        // Tap alternative to dragging the handles.
                        HStack {
                            nudgeGroup(
                                title: "Start",
                                minus: { model.nudgeStart(-0.1) },
                                plus: { model.nudgeStart(0.1) }
                            )
                            Spacer()
                            nudgeGroup(
                                title: "End",
                                minus: { model.nudgeEnd(-0.1) },
                                plus: { model.nudgeEnd(0.1) }
                            )
                        }
                    }

                    section("Crop") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(CropAspect.allCases) { a in
                                    Button(a.rawValue) { model.aspect = a }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .tint(model.aspect == a ? .accentColor : .secondary)
                                        .accessibilityLabel("Crop \(a.rawValue)")
                                        .accessibilityAddTraits(model.aspect == a ? .isSelected : [])
                                }
                            }
                        }

                        // Tap alternatives to pinch and drag.
                        ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            iconButton("minus.magnifyingglass", label: "Zoom out") { model.zoom(by: 1 / 1.25) }
                            iconButton("plus.magnifyingglass", label: "Zoom in") { model.zoom(by: 1.25) }
                            iconButton("arrow.left", label: "Move crop left") { model.moveCrop(dx: -1, dy: 0) }
                            iconButton("arrow.up", label: "Move crop up") { model.moveCrop(dx: 0, dy: -1) }
                            iconButton("arrow.down", label: "Move crop down") { model.moveCrop(dx: 0, dy: 1) }
                            iconButton("arrow.right", label: "Move crop right") { model.moveCrop(dx: 1, dy: 0) }
                            iconButton("arrow.counterclockwise", label: "Reset crop") { model.resetCrop() }
                        }
                        }
                        Text("Drag the video to move it, pinch to zoom, or use these buttons.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    section("Loop") {
                        Picker("Loop", selection: $model.loopMode) {
                            ForEach(LoopMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if !model.previewShowsLoopMode {
                            Text("This video can't play backwards in the preview, but the GIF will be \(model.loopMode.rawValue.lowercased()).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    section("Speed") {
                        Picker("Speed", selection: $model.speed) {
                            Text("0.5x").tag(0.5)
                            Text("1x").tag(1.0)
                            Text("1.5x").tag(1.5)
                            Text("2x").tag(2.0)
                        }
                        .pickerStyle(.segmented)
                    }

                    section("Size") {
                        Picker("Width", selection: $model.width) {
                            Text("320").tag(320)
                            Text("480").tag(480)
                            Text("720").tag(720)
                        }
                        .pickerStyle(.segmented)
                    }

                    section("Frame rate") {
                        Picker("Frame rate", selection: $model.fps) {
                            Text("10 fps").tag(10)
                            Text("14 fps").tag(14)
                            Text("15 fps").tag(15)
                            Text("24 fps").tag(24)
                        }
                        .pickerStyle(.segmented)
                    }

                    let size = model.outputSize
                    Text("\(Int(size.width))×\(Int(size.height)) · about \(model.estimatedFrames) frames")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Output \(Int(size.width)) by \(Int(size.height)), about \(model.estimatedFrames) frames")

                    if let err = model.exportError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }

                    Button {
                        model.makeGIF()
                    } label: {
                        Label("Make GIF", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isExporting || model.clipLength < EditorModel.minClip)
                }
                .padding()
            }
        }
        .overlay {
            if model.isExporting {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView(value: model.progress)
                            .frame(width: 200)
                            .accessibilityLabel("Making GIF")
                        Text("Making GIF... \(Int(model.progress * 100))%")
                        Button("Cancel", role: .cancel) { model.cancelExport() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    /// "Start  [−] [+]" with 44-point buttons that move a handle by 0.1 s.
    private func nudgeGroup(title: String, minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline).accessibilityHidden(true)
            iconButton("minus", label: "\(title) earlier by a tenth of a second", action: minus)
            iconButton("plus", label: "\(title) later by a tenth of a second", action: plus)
        }
    }

    /// Icon-only button with at least a 44 × 44 point tap area and a VoiceOver label.
    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label)
    }
}
