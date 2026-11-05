import Photos
import SwiftUI
import UniformTypeIdentifiers

struct ResultView: View {
    let result: GIFResult
    @State private var status: String?
    @State private var isSaving = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    GIFPlayerView(url: result.url)
                        .aspectRatio(result.pixelSize, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 440)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityElement()
                        .accessibilityLabel("Your GIF, \(result.loopMode.rawValue) loop, \(Int(result.pixelSize.width)) by \(Int(result.pixelSize.height))")
                        .accessibilityAddTraits(.isImage)

                    Text("\(result.loopMode.rawValue) · \(Int(result.pixelSize.width))×\(Int(result.pixelSize.height)) · \(result.frameCount) frames · \(ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)

                    if let note = result.note {
                        Label(note, systemImage: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.yellow)
                            .multilineTextAlignment(.center)
                    }

                    HStack(alignment: .top, spacing: 28) {
                        Button {
                            Task { await save() }
                        } label: {
                            roundAction("arrow.down.to.line", title: "Save", prominent: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                        .accessibilityLabel("Save to Photos")

                        ShareLink(item: result.url) {
                            roundAction("square.and.arrow.up", title: "Share", prominent: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share")

                        Button {
                            copy()
                        } label: {
                            roundAction("doc.on.doc", title: "Copy", prominent: false)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Copy GIF")
                    }

                    if let status {
                        Text(status)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(20)
            }
        }
        .onChange(of: status) { _, message in
            // VoiceOver reads out "Saved", "Copied" and errors.
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .navigationTitle("Your GIF")
        .noSwipeBack()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func roundAction(_ icon: String, title: String, prominent: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    prominent ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.surface),
                    in: Circle()
                )
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
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
