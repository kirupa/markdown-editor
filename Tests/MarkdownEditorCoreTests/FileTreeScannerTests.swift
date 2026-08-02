import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("File tree scanner")
struct FileTreeScannerTests {
    @Test("Folders sort first and hidden items are skipped")
    func foldersSortFirstAndHiddenItemsAreSkipped() throws {
        try withTemporaryDirectory { root in
            let folder = root.appendingPathComponent(
                "Folder 10",
                isDirectory: true
            )
            let earlierFolder = root.appendingPathComponent(
                "Folder 2",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: earlierFolder,
                withIntermediateDirectories: true
            )
            try Data().write(
                to: root.appendingPathComponent("Notes.md")
            )
            try Data().write(
                to: root.appendingPathComponent(".hidden.md")
            )

            let entries = try FileTreeScanner().contents(of: root)

            #expect(
                entries.map(\.name)
                    == ["Folder 2", "Folder 10", "Notes.md"]
            )
            #expect(entries.prefix(2).allSatisfy { $0.isExpandable })
        }
    }

    @Test("Directory symlinks are visible but not expandable")
    func directorySymlinksAreNotExpandable() throws {
        try withTemporaryDirectory { root in
            let target = root.appendingPathComponent(
                "Target",
                isDirectory: true
            )
            let link = root.appendingPathComponent(
                "Linked Folder",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: target
            )

            let entry = try #require(
                FileTreeScanner().contents(of: root)
                    .first { $0.name == "Linked Folder" }
            )

            #expect(entry.isSymbolicLink)
            #expect(!entry.isExpandable)
        }
    }

    @Test("Packages are visible but not expandable")
    func packagesAreNotExpandable() throws {
        try withTemporaryDirectory { root in
            let package = root.appendingPathComponent(
                "Example.app",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: true
            )

            let entry = try #require(
                FileTreeScanner().contents(of: root)
                    .first { $0.name == "Example.app" }
            )

            #expect(entry.isPackage)
            #expect(!entry.isExpandable)
        }
    }

    @Test("Markdown detection accepts both standard extensions")
    func markdownDetectionAcceptsExtensions() {
        #expect(
            FileTreeScanner.isMarkdownDocument(
                URL(fileURLWithPath: "/tmp/notes.md")
            )
        )
        #expect(
            FileTreeScanner.isMarkdownDocument(
                URL(fileURLWithPath: "/tmp/notes.MARKDOWN")
            )
        )
        #expect(
            !FileTreeScanner.isMarkdownDocument(
                URL(fileURLWithPath: "/tmp/notes.txt")
            )
        )
    }

    @Test("Directory ancestors reach the filesystem root")
    func directoryAncestorsReachRoot() {
        let ancestors = FileTreeScanner.ancestorDirectories(
            startingAt: URL(fileURLWithPath: "/Users/example/Documents")
        )

        #expect(
            ancestors.map(\.path)
                == [
                    "/Users/example/Documents",
                    "/Users/example",
                    "/Users",
                    "/"
                ]
        )
        #expect(
            FileTreeScanner.ancestorDirectories(
                startingAt: URL(fileURLWithPath: "/")
            ).map(\.path) == ["/"]
        )
    }

    @Test("Scanning a regular file reports an error")
    func regularFileIsRejected() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("Notes.md")
            try Data().write(to: file)

            #expect(throws: FileTreeScannerError.self) {
                try FileTreeScanner().contents(of: file)
            }
        }
    }

    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }
}
