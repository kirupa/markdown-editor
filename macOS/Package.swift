// swift-tools-version: 6.0

import PackageDescription

// The macOS app. Everything shareable lives in ../Shared and is compiled
// again, unchanged, by the iOS app — see ../Shared/Package.swift.
let package = Package(
    name: "MarkdownEditor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "MarkdownEditor", targets: ["MarkdownEditor"])
    ],
    dependencies: [
        .package(path: "../Shared")
    ],
    targets: [
        .executableTarget(
            name: "MarkdownEditor",
            dependencies: [
                .product(name: "MarkdownEditorCore", package: "Shared"),
                .product(name: "MarkdownEditorUI", package: "Shared")
            ]
        )
    ]
)
