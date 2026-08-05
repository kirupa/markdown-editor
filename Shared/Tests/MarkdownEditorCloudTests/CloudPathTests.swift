import Foundation
import Testing
@testable import MarkdownEditorCloud

/// Path arithmetic for the cloud workspace.
///
/// These exist because the native cloud path has to reach the *same* answers
/// the web and PHP builds reach — the same account is opened by all of them,
/// and a disagreement about what a collision is, or where a document's images
/// live, would corrupt a workspace rather than merely look wrong. Where a rule
/// was ported rather than invented, the test names say which behaviour it is
/// matching.
@Suite("Cloud paths")
struct CloudPathTests {
    @Test("normalizing strips leading, trailing, and doubled separators")
    func normalizing() throws {
        #expect(try CloudPath.normalize("/Notes//Ideas.md/") == "Notes/Ideas.md")
        #expect(try CloudPath.normalize("") == "")
        #expect(try CloudPath.normalize("./Notes/./Ideas.md") == "Notes/Ideas.md")
    }

    @Test("normalizing accepts a backslash separator")
    func backslashes() throws {
        #expect(try CloudPath.normalize("Notes\\Ideas.md") == "Notes/Ideas.md")
    }

    @Test("normalizing refuses \"..\", which would break path identity")
    func refusesDotDot() {
        #expect(throws: CloudError.self) { try CloudPath.normalize("Notes/../Ideas.md") }
        #expect(throws: CloudError.self) { try CloudPath.normalize("../secrets.md") }
    }

    @Test("name, parent, stem, and extension split the way PATHINFO does")
    func splitting() {
        #expect(CloudPath.name(of: "Notes/Ideas.md") == "Ideas.md")
        #expect(CloudPath.parent(of: "Notes/Ideas.md") == "Notes")
        #expect(CloudPath.parent(of: "Ideas.md") == "")
        #expect(CloudPath.stem(of: "Ideas.md") == "Ideas")
        #expect(CloudPath.fileExtension(of: "Ideas.MD") == "md")
    }

    @Test("a leading dot is an extension, not a stem — PHP splits on the last dot")
    func leadingDot() {
        // Looks wrong, kept deliberately: `assetsFolderName` depends on it and
        // every build refuses the bare `.assets` that falls out of it.
        #expect(CloudPath.stem(of: ".gitignore") == "")
        #expect(CloudPath.fileExtension(of: ".gitignore") == "gitignore")
        #expect(CloudPath.assetsFolderName(for: ".gitignore") == ".assets")
    }

    @Test("the assets folder is named after the document stem")
    func assetsFolder() {
        #expect(CloudPath.assetsFolderName(for: "Notes/Ideas.md") == "Ideas.assets")
    }

    @Test("descendancy respects the separator, so a folder cannot claim a sibling")
    func descendancy() {
        #expect(CloudPath.isDescendant("Notes/Ideas.md", of: "Notes"))
        // The case the range query gets wrong on its own.
        #expect(!CloudPath.isDescendant("Notes 2/Ideas.md", of: "Notes"))
        #expect(!CloudPath.isDescendant("Notes.md", of: "Notes"))
        #expect(CloudPath.isDescendant("Anything", of: ""))
    }

    @Test("rewriting repoints a subtree, including the folder itself")
    func rewriting() {
        #expect(CloudPath.rewrite("Notes", from: "Notes", to: "Archive") == "Archive")
        #expect(CloudPath.rewrite("Notes/Ideas.md", from: "Notes", to: "Archive") == "Archive/Ideas.md")
        #expect(CloudPath.rewrite("Notes 2/Ideas.md", from: "Notes", to: "Archive") == "Notes 2/Ideas.md")
    }

    @Test("a duplicate is named stem-2.ext, keeping the extension's case")
    func duplicateNaming() throws {
        #expect(try CloudPath.nextAvailableName(taken: ["Ideas.md"], for: "Ideas.md") == "Ideas-2.md")
        #expect(try CloudPath.nextAvailableName(taken: ["Ideas.md", "Ideas-2.md"], for: "Ideas.md") == "Ideas-3.md")
        #expect(try CloudPath.nextAvailableName(taken: ["Shot.PNG"], for: "Shot.PNG") == "Shot-2.PNG")
        #expect(try CloudPath.nextAvailableName(taken: ["Readme"], for: "Readme") == "Readme-2")
    }

    @Test("folders sort before files, then in natural case-insensitive order")
    func ordering() {
        let entries = [
            CloudEntry(node: document("banana.md")),
            CloudEntry(node: document("Apple.md")),
            CloudEntry(node: folder("Zebra")),
            CloudEntry(node: document("Folder 10.md")),
            CloudEntry(node: document("Folder 2.md")),
        ].sorted(by: CloudPath.compare)

        #expect(entries.map(\.name) == ["Zebra", "Apple.md", "banana.md", "Folder 2.md", "Folder 10.md"])
    }

    @Test("a document ID is the path, encoded exactly as encodeURIComponent does")
    func documentIdentity() throws {
        // Interop, not cosmetics: the web build writes IDs into this same
        // collection, so a different encoding would make one build unable to
        // find the other's documents.
        #expect(try CloudPath.documentId(for: "Notes/Ideas.md") == "Notes%2FIdeas.md")
        #expect(try CloudPath.documentId(for: "a b&c.md") == "a%20b%26c.md")
        #expect(try CloudPath.documentId(for: "caf\u{00E9}.md") == "caf%C3%A9.md")
        // encodeURIComponent leaves these alone; a stricter set would not.
        #expect(try CloudPath.documentId(for: "a-_.!~*'().md") == "a-_.!~*'().md")
    }

    @Test("a document ID round-trips back to its path")
    func documentIdRoundTrip() throws {
        for path in ["Notes/Ideas.md", "a b&c.md", "caf\u{00E9}.md", "100% done.md"] {
            let id = try CloudPath.documentId(for: path)
            #expect(CloudPath.path(fromDocumentId: id) == path)
        }
    }

    @Test("the workspace root is not a document")
    func rootIsNotADocument() {
        #expect(throws: CloudError.self) { try CloudPath.documentId(for: "") }
    }

    @Test("ancestor folders come back outermost first, excluding the node itself")
    func ancestors() {
        #expect(CloudPath.ancestorFolders(of: "a/b/c.md") == ["a", "a/b"])
        #expect(CloudPath.ancestorFolders(of: "c.md") == [])
        #expect(CloudPath.ancestorFolders(of: "") == [])
    }
}
