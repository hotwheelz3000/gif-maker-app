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

struct HomeView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var showCamera = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "photo.stack")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Turn a video into a GIF")
                    .font(.title2.bold())
                Text("Trim it, crop it, pick a loop style, then save or share.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()

                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    Label("Choose a Video", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    showCamera = true
                } label: {
                    Label("Record Video", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!cameraAvailable)

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("GIF Maker")
            .overlay {
                if isLoading {
                    ProgressView("Loading video...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { url in videoURL = url }
                    .ignoresSafeArea()
            }
            .navigationDestination(item: $videoURL) { url in
                EditorView(url: url)
            }
        }
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
                videoURL = movie.url
            } else {
                errorMessage = "Couldn't open that video."
            }
        } catch {
            errorMessage = "Couldn't open that video: \(error.localizedDescription)"
        }
    }
}
