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

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Trim") {
                        TrimBar(model: model)
                        HStack {
                            Text("\(time(model.start)) – \(time(model.end))")
                            Spacer()
                            Text(String(format: "%.1fs (max %.0fs)", model.clipLength, EditorModel.maxClip))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.monospacedDigit())
                    }

                    section("Crop") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(CropAspect.allCases) { a in
                                    Button(a.rawValue) { model.aspect = a }
                                        .buttonStyle(.bordered)
                                        .tint(model.aspect == a ? .accentColor : .secondary)
                                }
                                Button("Reset") { model.resetCrop() }
                                    .buttonStyle(.borderless)
                            }
                        }
                        Text("Drag the video to move it. Pinch to zoom.")
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
                        Picker("FPS", selection: $model.fps) {
                            Text("10 fps").tag(10)
                            Text("15 fps").tag(15)
                            Text("24 fps").tag(24)
                        }
                        .pickerStyle(.segmented)
                    }

                    let size = model.outputSize
                    Text("\(Int(size.width))×\(Int(size.height)) · about \(model.estimatedFrames) frames")
                        .font(.caption).foregroundStyle(.secondary)

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
                        Text("Making GIF... \(Int(model.progress * 100))%")
                        Button("Cancel", role: .cancel) { model.cancelExport() }
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
            Text(title).font(.headline)
            content()
        }
    }

    private func time(_ s: Double) -> String {
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%d:%04.1f", m, sec)
    }
}
