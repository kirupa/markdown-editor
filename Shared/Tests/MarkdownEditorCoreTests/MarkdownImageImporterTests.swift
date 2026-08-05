import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Markdown image importer")
struct MarkdownImageImporterTests {
    @Test("Import copies image beside document and builds relative reference")
    func importCopiesImageBesideDocumentAndBuildsRelativeReference() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let documentURL = temporaryDirectory
                .appendingPathComponent("My Notes.md")
            let sourceURL = temporaryDirectory
                .appendingPathComponent("Header image.PNG")
            try Data("image".utf8).write(to: sourceURL)

            let result = try MarkdownImageImporter().importImage(
                at: sourceURL,
                forDocumentAt: documentURL
            )

            #expect(
                result.destinationURL
                    == temporaryDirectory
                        .appendingPathComponent(
                            "My Notes.assets",
                            isDirectory: true
                        )
                        .appendingPathComponent("Header image.PNG")
            )
            #expect(
                try Data(contentsOf: result.destinationURL)
                    == Data("image".utf8)
            )
            #expect(
                result.relativePath
                    == "My%20Notes.assets/Header%20image.PNG"
            )
            #expect(
                result.markdownReference
                    == "![Header image](My%20Notes.assets/Header%20image.PNG)"
            )
        }
    }

    @Test("Import uses numbered filename when destination exists")
    func importUsesNumberedFilenameWhenDestinationExists() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let documentURL = temporaryDirectory
                .appendingPathComponent("Post.md")
            let sourceURL = temporaryDirectory
                .appendingPathComponent("photo.png")
            let assetsDirectory = temporaryDirectory
                .appendingPathComponent("Post.assets", isDirectory: true)
            try FileManager.default.createDirectory(
                at: assetsDirectory,
                withIntermediateDirectories: true
            )
            try Data("original".utf8).write(
                to: assetsDirectory.appendingPathComponent("photo.png")
            )
            try Data("new".utf8).write(to: sourceURL)

            let result = try MarkdownImageImporter().importImage(
                at: sourceURL,
                forDocumentAt: documentURL
            )

            #expect(
                result.destinationURL.lastPathComponent == "photo-2.png"
            )
            #expect(
                try Data(
                    contentsOf: assetsDirectory.appendingPathComponent(
                        "photo.png"
                    )
                )
                    == Data("original".utf8)
            )
            #expect(
                try Data(contentsOf: result.destinationURL)
                    == Data("new".utf8)
            )
        }
    }

    @Test("Unsaved document is rejected")
    func unsavedDocumentIsRejected() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sourceURL = temporaryDirectory
                .appendingPathComponent("photo.png")
            try Data().write(to: sourceURL)

            do {
                _ = try MarkdownImageImporter().importImage(
                    at: sourceURL,
                    forDocumentAt: nil
                )
                Issue.record("Expected an unsaved-document error")
            } catch MarkdownImageImportError.documentHasNoFileLocation {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Unsupported file type is rejected")
    func unsupportedFileTypeIsRejected() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let sourceURL = temporaryDirectory
                .appendingPathComponent("photo.pdf")
            try Data().write(to: sourceURL)

            do {
                _ = try MarkdownImageImporter().importImage(
                    at: sourceURL,
                    forDocumentAt: temporaryDirectory
                        .appendingPathComponent("Post.md")
                )
                Issue.record("Expected an unsupported-type error")
            } catch MarkdownImageImportError.unsupportedImageType(
                let filenameExtension
            ) {
                #expect(filenameExtension == "pdf")
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Symlinked assets directory is rejected")
    func symlinkedAssetsDirectoryIsRejected() throws {
        try withTemporaryDirectory { temporaryDirectory in
            let documentURL = temporaryDirectory
                .appendingPathComponent("Post.md")
            let sourceURL = temporaryDirectory
                .appendingPathComponent("photo.png")
            let outsideDirectory = temporaryDirectory
                .appendingPathComponent("Outside", isDirectory: true)
            let assetsDirectory = temporaryDirectory
                .appendingPathComponent("Post.assets", isDirectory: true)
            try Data("image".utf8).write(to: sourceURL)
            try FileManager.default.createDirectory(
                at: outsideDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: assetsDirectory,
                withDestinationURL: outsideDirectory
            )

            do {
                _ = try MarkdownImageImporter().importImage(
                    at: sourceURL,
                    forDocumentAt: documentURL
                )
                Issue.record("Expected an unsafe-assets-directory error")
            } catch MarkdownImageImportError.unsafeAssetsDirectory {
                #expect(
                    !FileManager.default.fileExists(
                        atPath: outsideDirectory
                            .appendingPathComponent("photo.png")
                            .path
                    )
                )
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test("Markdown reference escapes alt text")
    func markdownReferenceEscapesAltText() {
        #expect(
            MarkdownImageImporter.markdownImageReference(
                altText: #"a[b]\c"#,
                relativePath: "Post.assets/image.png"
            ) == #"![a\[b\]\\c](Post.assets/image.png)"#
        )
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try body(temporaryDirectory)
    }
}
