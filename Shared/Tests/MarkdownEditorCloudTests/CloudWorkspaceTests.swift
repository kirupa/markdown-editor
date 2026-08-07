import Foundation
import Testing
@testable import MarkdownEditorCloud

/// The decisions, run against the in-memory doubles.
///
/// These are the Swift half of a pair: `Web/public/tests/cloud-backend.test.js`
/// asserts the same things about the JavaScript build. Both builds write to the
/// same Firestore account, so a disagreement here is not a style difference —
/// it is one build corrupting the other's documents.
@Suite("Cloud workspace")
struct CloudWorkspaceTests {
    private func workspace(
        _ nodes: [CloudNode] = []
    ) -> (CloudWorkspace, InMemoryNodeStore, InMemoryAssetStore) {
        let store = InMemoryNodeStore(nodes)
        let assets = InMemoryAssetStore()
        return (CloudWorkspace(nodes: store, assets: assets), store, assets)
    }

    private func file(_ path: String, text: String = "", modified: Date = Date()) -> CloudNode {
        CloudNode(kind: .file, path: path, modified: modified, text: text, size: text.utf8.count)
    }

    private func folder(_ path: String) -> CloudNode {
        CloudNode(kind: .folder, path: path)
    }

    private func asset(_ path: String) -> CloudNode {
        CloudNode(
            kind: .asset,
            path: path,
            size: 4,
            storagePath: "\(path)#1",
            url: "https://storage.test/\(path)#1",
            contentType: "image/png"
        )
    }

    // MARK: - Listing

    @Test("Lists one level, folders first, and hides assets")
    func listsOneLevel() async throws {
        let (workspace, _, _) = workspace([
            file("Notes.md"),
            folder("Archive"),
            file("Archive/Deep.md"),
            asset("Notes.assets/shot.png"),
            folder("Notes.assets")
        ])

        let entries = try await workspace.list()
        // `Archive` before `Notes.md` because folders sort first; `Deep.md` is a
        // grandchild and must not appear; the assets folder is machinery, not
        // something anyone asked to see.
        #expect(entries.map(\.name) == ["Archive", "Notes.assets", "Notes.md"])
    }

    @Test("Sorts naturally, so Folder 2 precedes Folder 10")
    func sortsNaturally() async throws {
        let (workspace, _, _) = workspace([
            folder("Folder 10"), folder("Folder 2"), file("b.md"), file("A.md")
        ])
        #expect(try await workspace.list().map(\.name) == ["Folder 2", "Folder 10", "A.md", "b.md"])
    }

    @Test("Every document in the account, newest first")
    func allDocumentsNewestFirst() async throws {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        let (workspace, _, _) = workspace([
            file("Old.md", modified: old),
            file("Deep/New.md", modified: recent),
            file("notes.txt", modified: recent),
            asset("Old.assets/a.png")
        ])

        let documents = try await workspace.allDocuments()
        // `.txt` is not Markdown and assets are not documents.
        #expect(documents.map(\.path) == ["Deep/New.md", "Old.md"])
    }

    // MARK: - Reading

    @Test("Reads a document with its image URLs resolved up front")
    func readsDocumentWithImageURLs() async throws {
        let (workspace, _, _) = workspace([
            file("Trip.md", text: "![a](Trip.assets/a.png)"),
            asset("Trip.assets/a.png")
        ])

        let document = try await workspace.readDocument(at: "Trip.md")
        #expect(document.text == "![a](Trip.assets/a.png)")
        #expect(document.imageURLs["Trip.assets/a.png"] == "https://storage.test/Trip.assets/a.png#1")
    }

    @Test("Reading a missing document says so rather than returning nothing")
    func readingMissingDocumentThrows() async throws {
        let (workspace, _, _) = workspace()
        await #expect(throws: CloudError.self) {
            try await workspace.readDocument(at: "Gone.md")
        }
    }

    @Test("Reading a folder as a document is refused")
    func readingFolderAsDocumentThrows() async throws {
        let (workspace, _, _) = workspace([folder("Archive")])
        await #expect(throws: CloudError.self) {
            try await workspace.readDocument(at: "Archive")
        }
    }

    // MARK: - Writing

    @Test("Saving creates the folders above it in the same batch")
    func saveCreatesMissingAncestors() async throws {
        let (workspace, store, _) = workspace()
        try await workspace.saveDocument("hi", to: "a/b/c.md")

        #expect(store.allPaths == ["a", "a/b", "a/b/c.md"])
        // One batch: a half-created tree is worse than no tree.
        #expect(store.commits.count == 1)
    }

    @Test("Saving refuses a document over the Firestore ceiling")
    func saveRefusesOversizeDocument() async throws {
        let (workspace, store, _) = workspace()
        let tooBig = String(repeating: "x", count: CloudWorkspace.maximumDocumentBytes + 1)

        await #expect(throws: CloudError.self) {
            try await workspace.saveDocument(tooBig, to: "Big.md")
        }
        // Refused before writing, not after a confusing failure from Firestore.
        #expect(store.allPaths.isEmpty)
    }

    @Test("Size is counted in UTF-8 bytes, not characters")
    func sizeCountsBytes() async throws {
        let (workspace, _, _) = workspace()
        let node = try await workspace.saveDocument("né😀", to: "Unicode.md")
        // 1 + 2 + 4. Counting characters would let a document through that
        // Firestore then rejects.
        #expect(node.size == 7)
    }

    @Test("Creating a document does not overwrite one already there")
    func createDocumentAvoidsCollision() async throws {
        let (workspace, _, _) = workspace([file("Notes.md", text: "original")])
        let path = try await workspace.createDocument(named: "Notes.md", in: "")

        #expect(path == "Notes-2.md")
        #expect(try await workspace.readDocument(at: "Notes.md").text == "original")
    }

    @Test("A name typed without an extension becomes a Markdown document")
    func createDocumentAddsMarkdownExtension() async throws {
        let (workspace, _, _) = workspace()
        #expect(try await workspace.createDocument(named: "Shopping") == "Shopping.md")
        // `.markdown` counts too, so it is left alone.
        #expect(try await workspace.createDocument(named: "Long.markdown") == "Long.markdown")
    }

    @Test("A name taken in one folder is free in another")
    func collisionsAreOnlyWithinAFolder() async throws {
        let (workspace, _, _) = workspace([file("Notes.md"), folder("Archive")])
        #expect(try await workspace.createDocument(named: "Notes.md", in: "Archive") == "Archive/Notes.md")
    }

    @Test("Collisions keep counting past the second")
    func createDocumentCountsPastSecond() async throws {
        let (workspace, _, _) = workspace([
            file("Notes.md"), file("Notes-2.md"), file("Notes-3.md")
        ])
        #expect(try await workspace.createDocument(named: "Notes.md") == "Notes-4.md")
    }

    // MARK: - The prefix boundary

    @Test("Renaming a folder leaves its similarly named neighbours alone")
    func renameDoesNotTouchPrefixNeighbours() async throws {
        // The trap. Firestore's range query for `Notes` also returns
        // `Notes 2/Out.md` and `Notes.md`, because both sort inside the range.
        // Rewriting those would move two unrelated things.
        let (workspace, store, _) = workspace([
            folder("Notes"),
            file("Notes/In.md"),
            folder("Notes 2"),
            file("Notes 2/Out.md"),
            file("Notes.md")
        ])

        try await workspace.rename("Notes", to: "Journal")

        #expect(store.allPaths == ["Journal", "Journal/In.md", "Notes 2", "Notes 2/Out.md", "Notes.md"])
    }

    @Test("Deleting a folder leaves its similarly named neighbours alone")
    func deleteDoesNotTouchPrefixNeighbours() async throws {
        let (workspace, store, _) = workspace([
            folder("Notes"), file("Notes/In.md"),
            folder("Notes 2"), file("Notes 2/Out.md"),
            file("Notes.md")
        ])

        try await workspace.delete("Notes")

        #expect(store.allPaths == ["Notes 2", "Notes 2/Out.md", "Notes.md"])
    }

    @Test("A document's image URLs do not leak in from a neighbouring document")
    func imageURLsDoNotLeakAcrossDocuments() async throws {
        // `Trip.assets` and `Trip 2.assets` share a prefix in exactly the way
        // that catches a range query out.
        let (workspace, _, _) = workspace([
            file("Trip.md"), asset("Trip.assets/mine.png"),
            file("Trip 2.md"), asset("Trip 2.assets/theirs.png")
        ])

        let urls = try await workspace.imageURLs(forDocumentAt: "Trip.md")
        #expect(Array(urls.keys) == ["Trip.assets/mine.png"])
    }

    // MARK: - Moving

    @Test("Renaming a document takes its images with it and rewrites the references")
    func renameMovesAssetsAndRewritesReferences() async throws {
        let (workspace, store, _) = workspace([
            file("Trip.md", text: "before\n\n![shot](Trip.assets/shot.png)\n"),
            folder("Trip.assets"),
            asset("Trip.assets/shot.png")
        ])

        let destination = try await workspace.rename("Trip.md", to: "Holiday.md")

        #expect(destination == "Holiday.md")
        #expect(store.node(at: "Holiday.assets/shot.png") != nil)
        #expect(store.node(at: "Trip.assets/shot.png") == nil)
        // Moving the file without rewriting the text would leave a broken image
        // in a document that looked fine a second ago.
        #expect(store.node(at: "Holiday.md")?.text == "before\n\n![shot](Holiday.assets/shot.png)\n")
    }

    @Test("Rewriting references leaves other documents' folders alone")
    func rewriteOnlyTouchesOwnAssetsFolder() async throws {
        let (workspace, store, _) = workspace([
            file("Trip.md", text: "![a](Trip.assets/a.png)\n![b](Other.assets/b.png)\n"),
            asset("Trip.assets/a.png")
        ])

        try await workspace.rename("Trip.md", to: "Holiday.md")

        #expect(store.node(at: "Holiday.md")?.text == "![a](Holiday.assets/a.png)\n![b](Other.assets/b.png)\n")
    }

    @Test("A folder cannot be moved inside itself")
    func cannotMoveFolderIntoItself() async throws {
        let (workspace, store, _) = workspace([folder("Notes"), file("Notes/In.md")])

        await #expect(throws: CloudError.self) {
            try await workspace.move("Notes", into: "Notes/Deep")
        }
        #expect(store.allPaths == ["Notes", "Notes/In.md"])
    }

    @Test("Moving onto an occupied path is refused rather than silently overwriting")
    func moveOntoOccupiedPathThrows() async throws {
        let (workspace, store, _) = workspace([
            file("A.md", text: "a"), folder("Archive"), file("Archive/A.md", text: "keep")
        ])

        await #expect(throws: CloudError.self) {
            try await workspace.move("A.md", into: "Archive")
        }
        #expect(store.node(at: "Archive/A.md")?.text == "keep")
    }

    @Test("Moving a folder repoints every descendant, at any depth")
    func moveFolderRepointsWholeSubtree() async throws {
        let (workspace, store, _) = workspace([
            folder("Notes"), folder("Notes/2024"), file("Notes/2024/Jan.md"), folder("Archive")
        ])

        try await workspace.move("Notes", into: "Archive")

        #expect(store.allPaths == ["Archive", "Archive/Notes", "Archive/Notes/2024", "Archive/Notes/2024/Jan.md"])
    }

    @Test("Every create is ordered before the delete it replaces")
    func writesCreateBeforeDelete() async throws {
        let (workspace, store, _) = workspace([folder("Notes"), file("Notes/In.md")])

        try await workspace.rename("Notes", to: "Journal")

        let batch = try #require(store.commits.last)
        let removals = batch.indices.filter { batch[$0].isRemoval }
        let creates = batch.indices.filter { !batch[$0].isRemoval }
        let firstRemoval = try #require(removals.first)
        let lastCreate = try #require(creates.last)
        // If the batch is interrupted, duplicated nodes are recoverable and
        // deleted ones are not.
        #expect(lastCreate < firstRemoval)
    }

    @Test("Moving to where it already is does nothing at all")
    func moveToSamePlaceIsNoOp() async throws {
        let (workspace, store, _) = workspace([file("A.md")])
        #expect(try await workspace.move("A.md", into: "") == "A.md")
        #expect(store.commits.isEmpty)
    }

    @Test("The root cannot be renamed, moved, or deleted")
    func rootIsProtected() async throws {
        let (workspace, _, _) = workspace([file("A.md")])
        await #expect(throws: CloudError.self) { try await workspace.rename("", to: "X") }
        await #expect(throws: CloudError.self) { try await workspace.delete("/") }
    }

    // MARK: - Deleting

    @Test("Deleting a document leaves its images behind")
    func deleteLeavesAssetsBehind() async throws {
        // The originals may exist nowhere else. Every other build behaves this
        // way, and a document deleted by accident is recoverable if its images
        // outlive it.
        let (workspace, store, assets) = workspace([
            file("Trip.md"), folder("Trip.assets"), asset("Trip.assets/shot.png")
        ])

        try await workspace.delete("Trip.md")

        #expect(store.node(at: "Trip.assets/shot.png") != nil)
        #expect(assets.removed.isEmpty)
    }

    @Test("Deleting a folder clears the Storage objects underneath it")
    func deleteFolderRemovesStorageObjects() async throws {
        let (workspace, _, assets) = workspace([
            folder("Archive"), file("Archive/Trip.md"),
            folder("Archive/Trip.assets"), asset("Archive/Trip.assets/shot.png")
        ])

        try await workspace.delete("Archive")

        // Otherwise the bytes are billed forever with nothing pointing at them.
        #expect(assets.removed == ["Archive/Trip.assets/shot.png#1"])
    }

    // MARK: - Images

    @Test("Importing an image stores it and returns Markdown to insert")
    func importImageReturnsMarkdown() async throws {
        let (workspace, store, assets) = workspace([file("Trip.md")])

        let result = try await workspace.importImage(
            Data([1, 2, 3]), named: "shot.png", intoDocumentAt: "Trip.md", contentType: "image/png"
        )

        #expect(result.path == "Trip.assets/shot.png")
        #expect(result.relativePath == "Trip.assets/shot.png")
        #expect(result.markdown == "![shot](Trip.assets/shot.png)")
        #expect(store.node(at: "Trip.assets/shot.png")?.kind == .asset)
        #expect(assets.storedPaths.count == 1)
    }

    @Test("A second image of the same name does not replace the first")
    func importImageAvoidsCollision() async throws {
        let (workspace, _, assets) = workspace([file("Trip.md"), asset("Trip.assets/shot.png")])

        let result = try await workspace.importImage(
            Data([9]), named: "shot.png", intoDocumentAt: "Trip.md"
        )

        #expect(result.path == "Trip.assets/shot-2.png")
        #expect(assets.storedPaths.first?.hasPrefix("Trip.assets/shot-2.png#") == true)
    }

    @Test("The Storage path is stamped so a replaced image is not served from cache")
    func importImageStampsStoragePath() async throws {
        let (workspace, store, _) = workspace([file("Trip.md")])
        try await workspace.importImage(Data([1]), named: "a.png", intoDocumentAt: "Trip.md")

        let storagePath = try #require(store.node(at: "Trip.assets/a.png")?.storagePath)
        let stamp = try #require(storagePath.split(separator: "#").last)
        #expect(Int(stamp) != nil)
        // The node path stays clean; only the object path carries the stamp.
        #expect(storagePath.hasPrefix("Trip.assets/a.png#"))
    }

    @Test("An image of exactly the limit is refused, because the rule refuses it")
    func importImageRefusesExactlyTheLimit() async throws {
        // `storage.rules` allows `request.resource.size < 10 * 1024 * 1024`, so
        // a file of exactly that size is denied by the server. The web build
        // had this as `>` and accepted it, which turned the clear message
        // below into a bare permission error.
        let (workspace, _, assets) = workspace([file("Trip.md")])
        await #expect(throws: CloudError.self) {
            try await workspace.importImage(
                Data(count: CloudWorkspace.maximumImageBytes),
                named: "exact.png", intoDocumentAt: "Trip.md"
            )
        }
        #expect(assets.storedPaths.isEmpty)

        try await workspace.importImage(
            Data(count: CloudWorkspace.maximumImageBytes - 1),
            named: "under.png", intoDocumentAt: "Trip.md"
        )
        #expect(assets.storedPaths.count == 1)
    }

    @Test("An image with no declared type is uploaded as an image anyway")
    func importImageDerivesContentType() async throws {
        let (workspace, store, assets) = workspace([file("Trip.md")])
        // Every platform can hand over a file with no type: a drag from some
        // applications, a paste, or bytes read straight off disk. The Storage
        // rules accept only image/*, so uploading it untyped is refused by the
        // server and looks to the user like nothing happened.
        try await workspace.importImage(Data([1]), named: "a.png", intoDocumentAt: "Trip.md")

        let storagePath = try #require(store.node(at: "Trip.assets/a.png")?.storagePath)
        #expect(assets.contentType(at: storagePath) == "image/png")
        #expect(store.node(at: "Trip.assets/a.png")?.contentType == "image/png")
    }

    @Test("A declared image type is kept, a wrong one is corrected")
    func importImageKeepsDeclaredType() async throws {
        let (workspace, store, assets) = workspace([file("Trip.md")])
        try await workspace.importImage(
            Data([1]), named: "a.jpg", intoDocumentAt: "Trip.md", contentType: "image/webp"
        )
        try await workspace.importImage(
            Data([1]), named: "b.jpg", intoDocumentAt: "Trip.md",
            contentType: "application/octet-stream"
        )

        let first = try #require(store.node(at: "Trip.assets/a.jpg")?.storagePath)
        let second = try #require(store.node(at: "Trip.assets/b.jpg")?.storagePath)
        #expect(assets.contentType(at: first) == "image/webp")
        #expect(assets.contentType(at: second) == "image/jpeg")
    }

    @Test("Every accepted extension maps to an image type")
    func everyExtensionMapsToAnImageType() async throws {
        let (workspace, _, assets) = workspace([file("Trip.md")])
        for extensionName in CloudWorkspace.imageExtensions.sorted() {
            try await workspace.importImage(
                Data([1]), named: "shot.\(extensionName)", intoDocumentAt: "Trip.md"
            )
        }
        // An extension the picker offers but the map misses would upload as
        // octet-stream and be refused by the rules.
        #expect(assets.storedTypes.count == CloudWorkspace.imageExtensions.count)
        #expect(assets.storedTypes.allSatisfy { $0.hasPrefix("image/") })
    }

    @Test("A file that is not an image is refused before anything is uploaded")
    func importImageRefusesNonImage() async throws {
        let (workspace, store, assets) = workspace([file("Trip.md")])

        await #expect(throws: CloudError.self) {
            try await workspace.importImage(Data([1]), named: "notes.pdf", intoDocumentAt: "Trip.md")
        }
        #expect(assets.storedPaths.isEmpty)
        #expect(store.node(at: "Trip.assets/notes.pdf") == nil)
    }

    @Test("An oversize image is refused before anything is uploaded")
    func importImageRefusesOversize() async throws {
        let (workspace, _, assets) = workspace([file("Trip.md")])
        let tooBig = Data(count: CloudWorkspace.maximumImageBytes + 1)

        await #expect(throws: CloudError.self) {
            try await workspace.importImage(tooBig, named: "big.png", intoDocumentAt: "Trip.md")
        }
        #expect(assets.storedPaths.isEmpty)
    }

    @Test("A space in the filename is percent-encoded in the reference")
    func importImageEncodesReference() async throws {
        let (workspace, _, _) = workspace([file("Trip.md")])

        let result = try await workspace.importImage(
            Data([1]), named: "my shot.png", intoDocumentAt: "Trip.md"
        )

        // An unencoded space ends the URL early in every Markdown parser, so
        // the image would render as nothing.
        #expect(result.markdown == "![my shot](Trip.assets/my%20shot.png)")
        #expect(result.path == "Trip.assets/my shot.png")
    }

    // MARK: - Watching

    @Test("Watching a document delivers the current value, then the changes")
    func watchDocumentDeliversCurrentThenChanges() async throws {
        let (workspace, _, _) = workspace([file("Live.md", text: "one")])
        let seen = Recorder<String?>()

        let subscription = workspace.watchDocument(at: "Live.md") { node in
            seen.append(node?.text)
        }
        try await workspace.saveDocument("two", to: "Live.md")
        subscription.cancel()
        try await workspace.saveDocument("three", to: "Live.md")

        // Attach snapshot, then the edit — and nothing after cancelling.
        #expect(seen.values == ["one", "two"])
    }

    @Test("Releasing the subscription detaches the listener")
    func releasingSubscriptionDetaches() async throws {
        let (workspace, store, _) = workspace([file("Live.md")])
        do {
            let subscription = workspace.watchDocument(at: "Live.md") { _ in }
            #expect(store.watcherCount == 1)
            _ = subscription
        }
        // Firestore bills per document read; a leaked listener bills forever.
        #expect(store.watcherCount == 0)
    }

    @Test("Watching a folder reports one level, in explorer order")
    func watchFolderReportsOneLevel() async throws {
        let (workspace, _, _) = workspace([file("b.md"), folder("A")])
        let seen = Recorder<[String]>()

        let subscription = workspace.watchFolder { entries in
            seen.append(entries.map(\.name))
        }
        defer { subscription.cancel() }

        #expect(seen.values.last == ["A", "b.md"])
    }
}

/// Collects callback values from the watchers without tripping Swift 6's
/// concurrency checking.
final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}
