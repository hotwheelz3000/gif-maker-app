// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GIFMaker",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "GIFMaker",
            targets: ["GIFMaker"]
        ),
    ],
    targets: [
        .target(
            name: "GIFMaker"
        ),
    ],
    // Swift 5 language mode: avoids Swift 6 strict-concurrency build errors
    // around AVFoundation callbacks.
    swiftLanguageModes: [.v5]
)
