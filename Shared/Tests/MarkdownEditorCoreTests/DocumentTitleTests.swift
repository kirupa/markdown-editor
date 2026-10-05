import Foundation
import Testing

@testable import MarkdownEditorCore

/// The name a never-saved draft goes by.
@Suite("Document title")
struct DocumentTitleTests {
    @Test("A Heading 1 on the first written line is the title, as typed")
    func headingOne() {
        #expect(DocumentTitle.title(of: "# Field notes on speed\n\nBody.") == "Field notes on speed")
        #expect(DocumentTitle.title(of: "\n\n  # Field notes on speed") == "Field notes on speed")
        #expect(DocumentTitle.title(of: "# Field notes on speed #\n") == "Field notes on speed")
        #expect(DocumentTitle.title(of: "# Why *pages* feel `slow`") == "Why pages feel slow")
        #expect(DocumentTitle.title(of: "# A [linked](https://example.com) title") == "A linked title")
    }

    @Test("Front matter is set aside, the way the critique sets it aside")
    func frontMatter() {
        let draft = """
            ---
            title: Not this one
            ---

            # Field notes on speed

            Body.
            """
        #expect(DocumentTitle.title(of: draft) == "Field notes on speed")
    }

    @Test("A draft that opens any other way has no title")
    func noTitle() {
        #expect(DocumentTitle.title(of: "") == nil)
        #expect(DocumentTitle.title(of: NewMarkdownDocument.text) == nil)
        #expect(DocumentTitle.title(of: "#    \n\nBody.") == nil)
        #expect(DocumentTitle.title(of: "## A section first\n\n# Title") == nil)
        #expect(DocumentTitle.title(of: "Opening sentence.\n\n# Title") == nil)
        #expect(DocumentTitle.title(of: "```\n# not a heading\n```") == nil)
        #expect(DocumentTitle.title(of: "#Title without a space") == nil)
    }

    @Test("The file name keeps the writer's letter case")
    func letterCase() {
        #expect(DocumentTitle.draftName(of: "# Field notes on speed") == "Field notes on speed")
        #expect(DocumentTitle.draftName(of: "# iOS and macOS") == "iOS and macOS")
    }

    @Test("Colons and slashes become dashes, and edge dots go")
    func unsafeCharacters() {
        #expect(DocumentTitle.fileName(for: "Speed: a field guide") == "Speed - a field guide")
        #expect(DocumentTitle.fileName(for: "Speed/latency") == "Speed-latency")
        #expect(DocumentTitle.fileName(for: "10:30 standup") == "10-30 standup")
        #expect(DocumentTitle.fileName(for: ".dotfiles explained") == "dotfiles explained")
        #expect(DocumentTitle.fileName(for: "The end.") == "The end")
        #expect(DocumentTitle.fileName(for: "Why?") == "Why?")
        #expect(DocumentTitle.fileName(for: "...") == nil)
        #expect(DocumentTitle.fileName(for: "/") == nil)
    }

    @Test("A long title is cut at a word, with nothing added")
    func longTitles() {
        let title = "A very long title that keeps going well past the point where anyone "
            + "would want to read it as the name of a file in Finder"
        let name = DocumentTitle.fileName(for: title)
        #expect(name == "A very long title that keeps going well past the point where anyone would want")
        #expect((name?.count ?? 0) <= DocumentTitle.longestName)

        let unbroken = String(repeating: "x", count: 120)
        #expect(DocumentTitle.fileName(for: unbroken)?.count == DocumentTitle.longestName)

        let emoji = String(repeating: "🚀", count: 80)
        #expect((DocumentTitle.fileName(for: emoji)?.utf8.count ?? 0) <= 240)
    }

    @Test("Section names still come from the same heading text")
    func sectionNames() {
        #expect(CritiqueOutline.Scan.sectionName(ofHeading: "## Setup ##") == "Setup")
        #expect(CritiqueOutline.Scan.sectionName(ofHeading: "##   ") == "Untitled section")
        #expect(CritiqueOutline.Scan.headingText("### *Why* it matters") == "Why it matters")
    }
}
