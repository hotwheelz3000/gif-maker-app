import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ResultView: View {
    let result: GIFResult
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GIFPlayerView(url: result.url)
                    .aspectRatio(result.pixelSize, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 420)
                    .background(Color.black.opacity(0.05))

                Text("\(Int(result.pixelSize.width))×\(Int(result.pixelSize.height)) · \(result.frameCount) frames · \(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task { await save() }
                } label: {
                    Label("Save to Photos", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSaving)

                ShareLink(item: result.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    copy()
                } label: {
                    Label("Copy GIF", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if let status {
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle("Your GIF")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            status = "Allow Photos access in Settings to save GIFs."
            return
        }
        let url = result.url
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: url, options: nil)
            }
            status = "Saved to Photos."
        } catch {
            status = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func copy() {
        guard let data = try? Data(contentsOf: result.url) else {
            status = "Couldn't copy the GIF."
            return
        }
        UIPasteboard.general.setData(data, forPasteboardType: UTType.gif.identifier)
        status = "Copied. Paste it into Messages or another app."
    }
}
