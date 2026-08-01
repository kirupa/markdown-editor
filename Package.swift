// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MarkdownEditor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MarkdownEditor", targets: ["MarkdownEditor"])
    ],
    targets: [
        .target(name: "MarkdownEditorCore"),
        .executableTarget(
            name: "MarkdownEditor",
            dependencies: ["MarkdownEditorCore"]
        ),
        .testTarget(
            name: "MarkdownEditorCoreTests",
            dependencies: ["MarkdownEditorCore"]
        )
    ]
)
