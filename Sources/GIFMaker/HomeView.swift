import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A video picked from Photos, copied into the app's temp folder.
struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return Movie(url: dest)
        }
    }
}

/// What the editor opens: a video, or a GIF to edit.
struct EditorInput: Hashable {
    let url: URL
    let isGIF: Bool
}

struct HomeView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var gifPickerItem: PhotosPickerItem?
    @State private var input: EditorInput?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()

                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(Theme.rainbow)
                        .accessibilityHidden(true)
                    Text("GIF Maker")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityAddTraits(.isHeader)
                    Text("Turn any video into a GIF, or edit one.\nTrim it, crop it, loop it.")
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()

                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("Choose a Video", systemImage: "photo.on.rectangle.angled")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle())

                    PhotosPicker(selection: $gifPickerItem, matching: .images) {
                        Label("Choose a GIF", systemImage: "square.stack.3d.down.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                    }

                    Text(BuildInfo.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(24)
            }
            .navigationTitle("")
            .toolbarBackground(Theme.background, for: .navigationBar)
            .overlay {
                if isLoading {
                    ProgressView("Loading...")
                        .tint(.white)
                        .padding(24)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .onChange(of: gifPickerItem) { _, item in
                guard let item else { return }
                Task { await loadGIF(item) }
            }
            .navigationDestination(item: $input) { input in
                EditorView(url: input.url, isGIF: input.isGIF)
            }
        }
        .tint(.white)
    }

    private func load(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            pickerItem = nil
        }
        do {
            if let movie = try await item.loadTransferable(type: Movie.self) {
                input = EditorInput(url: movie.url, isGIF: false)
            } else {
                errorMessage = "Couldn't open that video."
            }
        } catch {
            errorMessage = "Couldn't open that video: \(error.localizedDescription)"
        }
    }

    private func loadGIF(_ item: PhotosPickerItem) async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            gifPickerItem = nil
        }
        let notGIF = "That's not a GIF. Pick a GIF from your library."
        guard item.supportedContentTypes.contains(where: { $0.conforms(to: .gif) }) else {
            errorMessage = notGIF
            return
        }
        if let file = try? await item.loadTransferable(type: GIFFile.self) {
            input = EditorInput(url: file.url, isGIF: true)
        } else {
            errorMessage = "Couldn't open that GIF."
        }
    }
}
