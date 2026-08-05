// swift-tools-version: 6.0

import PackageDescription

// Everything both apps are built from. The macOS app and the iOS app are
// separate products with separate interface code, but they are not separate
// implementations: the Markdown language, the formatting commands, the
// palettes, and the styling all live here and are compiled once per platform
// from the same source. The Web build cannot share Swift, so it is a port
// validated by differential testing — see Web/README.md §4.
let package = Package(
    name: "MarkdownEditorKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "MarkdownEditorCore", targets: ["MarkdownEditorCore"]),
        .library(name: "MarkdownEditorUI", targets: ["MarkdownEditorUI"]),
        .library(name: "MarkdownEditorCloud", targets: ["MarkdownEditorCloud"])
    ],
    targets: [
        // Pure Foundation: no AppKit, no UIKit, no SwiftUI.
        .target(name: "MarkdownEditorCore"),
        // Cross-platform presentation: palettes, type scale, and the
        // attributed-string builders, written against the PlatformColor and
        // PlatformFont aliases rather than against AppKit or UIKit directly.
        .target(
            name: "MarkdownEditorUI",
            dependencies: ["MarkdownEditorCore"]
        ),
        // The cloud workspace's decisions: path arithmetic, collisions,
        // subtree moves, image import. No Firebase, on purpose — it talks to
        // the CloudNodeStore and CloudAssetStore protocols, so all of it runs
        // under test against in-memory doubles with no network.
        .target(
            name: "MarkdownEditorCloud",
            dependencies: ["MarkdownEditorCore"]
        ),
        .testTarget(
            name: "MarkdownEditorCoreTests",
            dependencies: ["MarkdownEditorCore"]
        ),
        .testTarget(
            name: "MarkdownEditorUITests",
            dependencies: ["MarkdownEditorUI"]
        ),
        .testTarget(
            name: "MarkdownEditorCloudTests",
            dependencies: ["MarkdownEditorCloud"]
        )
    ]
)
