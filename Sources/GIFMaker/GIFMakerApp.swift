import SwiftUI

@main
struct GIFMakerApp: App {
    init() {
        Self.clearTemporaryFiles()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }

    /// Copied videos and made GIFs live in the temp folder; clear them at launch
    /// (anything worth keeping was already saved to Photos or shared).
    private static func clearTemporaryFiles() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}
