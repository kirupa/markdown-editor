// swift-tools-version: 6.0

import PackageDescription

// The Firebase adapter, kept in its own package on purpose.
//
// This is where the project's one third-party dependency lives — a deliberate
// reversal of the rule that there would be none, made because Firestore's
// offline cache and its change listeners are the whole point and neither
// exists over the REST API. Both would have to be rebuilt by hand, and worse.
//
// It is a separate package rather than another target in ../Package.swift so
// that `swift test` there neither builds nor downloads any of it. The tests
// cover the decisions, which live in MarkdownEditorCloud and have no Firebase
// in them; keeping the two apart is what lets the test loop stay fast and
// offline. Only the apps depend on this.
let package = Package(
    name: "MarkdownEditorFirebaseKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "MarkdownEditorFirebase", targets: ["MarkdownEditorFirebase"])
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.17.0")
    ],
    targets: [
        // As small as it can be: configuration, sign-in, and the two store
        // protocols implemented against real Firestore and Cloud Storage.
        // Everything with a decision in it is next door in MarkdownEditorCloud.
        .target(
            name: "MarkdownEditorFirebase",
            dependencies: [
                .product(name: "MarkdownEditorCloud", package: "Shared"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk")
            ]
        ),
        // Covers the configuration, not the adapter: a wrong value here fails
        // at runtime with a message that names the wrong cause.
        .testTarget(
            name: "MarkdownEditorFirebaseTests",
            dependencies: ["MarkdownEditorFirebase"]
        )
    ]
)
