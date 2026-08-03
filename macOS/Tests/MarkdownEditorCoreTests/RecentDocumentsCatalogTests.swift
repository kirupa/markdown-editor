import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Recent documents catalog")
struct RecentDocumentsCatalogTests {
    @Test("Preferred order wins and duplicates collapse to one entry")
    func preferredOrderWinsAndDuplicatesCollapse() {
        let notes = URL(fileURLWithPath: "/tmp/notes.md")
        let readme = URL(fileURLWithPath: "/tmp/README.md")
        let duplicate = URL(fileURLWithPath: "/tmp/./notes.md")

        let merged = RecentDocumentsCatalog.merged(
            preferred: [notes, readme],
            additional: [duplicate, readme]
        )

        #expect(merged.map(\.path) == ["/tmp/notes.md", "/tmp/README.md"])
    }

    @Test("Only Markdown files are kept")
    func onlyMarkdownFilesAreKept() {
        let merged = RecentDocumentsCatalog.merged(
            preferred: [
                URL(fileURLWithPath: "/tmp/notes.md"),
                URL(fileURLWithPath: "/tmp/photo.png"),
                URL(fileURLWithPath: "/tmp/journal.MARKDOWN"),
                URL(fileURLWithPath: "/tmp/plain.txt")
            ]
        )

        #expect(
            merged.map(\.lastPathComponent) == ["notes.md", "journal.MARKDOWN"]
        )
    }

    @Test("The merged list never grows past the limit")
    func mergedListNeverGrowsPastTheLimit() {
        let urls = (1...10).map {
            URL(fileURLWithPath: "/tmp/note-\($0).md")
        }

        let merged = RecentDocumentsCatalog.merged(preferred: urls, limit: 4)

        #expect(merged.count == 4)
        #expect(merged.first?.lastPathComponent == "note-1.md")
        #expect(merged.last?.lastPathComponent == "note-4.md")
    }

    @Test("Promoting moves an existing entry to the front")
    func promotingMovesAnExistingEntryToTheFront() {
        let first = URL(fileURLWithPath: "/tmp/a.md")
        let second = URL(fileURLWithPath: "/tmp/b.md")
        let third = URL(fileURLWithPath: "/tmp/c.md")

        let promoted = RecentDocumentsCatalog.promoting(
            third,
            in: [first, second, third]
        )

        #expect(promoted.map(\.lastPathComponent) == ["c.md", "a.md", "b.md"])
    }

    @Test("Removing compares standardized paths")
    func removingComparesStandardizedPaths() {
        let remaining = RecentDocumentsCatalog.removing(
            URL(fileURLWithPath: "/tmp/sub/../a.md"),
            from: [
                URL(fileURLWithPath: "/tmp/a.md"),
                URL(fileURLWithPath: "/tmp/b.md")
            ]
        )

        #expect(remaining.map(\.lastPathComponent) == ["b.md"])
    }

    @Test("Entries skip files that are gone and folders")
    func entriesSkipFilesThatAreGoneAndFolders() throws {
        try withTemporaryDirectory { root in
            let present = root.appendingPathComponent("present.md")
            let missing = root.appendingPathComponent("missing.md")
            let folder = root.appendingPathComponent("folder.md", isDirectory: true)
            try Data("# Present".utf8).write(to: present)
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let entries = RecentDocumentsCatalog.entries(
                for: [missing, folder, present]
            )

            #expect(entries.map(\.name) == ["present.md"])
            #expect(entries.first?.modificationDate != nil)
        }
    }

    @Test("Entries stop at the display limit")
    func entriesStopAtTheDisplayLimit() throws {
        try withTemporaryDirectory { root in
            let urls = try (1...5).map { index -> URL in
                let url = root.appendingPathComponent("note-\(index).md")
                try Data().write(to: url)
                return url
            }

            let entries = RecentDocumentsCatalog.entries(for: urls, limit: 3)

            #expect(entries.map(\.name) == [
                "note-1.md",
                "note-2.md",
                "note-3.md"
            ])
        }
    }

    @Test("Existing keeps only paths that still resolve to a file")
    func existingKeepsOnlyPathsThatStillResolveToAFile() throws {
        try withTemporaryDirectory { root in
            let present = root.appendingPathComponent("present.md")
            try Data().write(to: present)
            let missing = root.appendingPathComponent("missing.md")

            let surviving = RecentDocumentsCatalog.existing([present, missing])

            #expect(surviving.map(\.lastPathComponent) == ["present.md"])
        }
    }

    @Test("Home directory paths shorten to a tilde")
    func homeDirectoryPathsShortenToATilde() {
        let home = "/Users/kirupa"

        #expect(
            RecentDocumentsCatalog.displayPath(
                for: URL(fileURLWithPath: "/Users/kirupa/Documents/Notes"),
                homeDirectoryPath: home
            ) == "~/Documents/Notes"
        )
        #expect(
            RecentDocumentsCatalog.displayPath(
                for: URL(fileURLWithPath: "/Users/kirupa"),
                homeDirectoryPath: home
            ) == "~"
        )
    }

    @Test("Paths outside the home directory stay absolute")
    func pathsOutsideTheHomeDirectoryStayAbsolute() {
        #expect(
            RecentDocumentsCatalog.displayPath(
                for: URL(fileURLWithPath: "/Volumes/Work/Docs"),
                homeDirectoryPath: "/Users/kirupa"
            ) == "/Volumes/Work/Docs"
        )
        #expect(
            RecentDocumentsCatalog.displayPath(
                for: URL(fileURLWithPath: "/Users/kirupa2/Docs"),
                homeDirectoryPath: "/Users/kirupa"
            ) == "/Users/kirupa2/Docs"
        )
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
