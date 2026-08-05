import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Markdown text insertion")
struct MarkdownTextInsertionTests {
    @Test("Inserting at the caret leaves the caret after the text")
    func insertsAtCaret() {
        let result = MarkdownTextInsertion.insert(
            "![Photo](Notes.assets/photo.png)",
            in: "Before after",
            selection: NSRange(location: 7, length: 0)
        )

        #expect(result.text == "Before ![Photo](Notes.assets/photo.png)after")
        #expect(result.selection == NSRange(location: 39, length: 0))
    }

    @Test("Inserting over a selection replaces it")
    func replacesSelection() {
        let result = MarkdownTextInsertion.insert(
            "![](a.png)",
            in: "Keep this remove that",
            selection: NSRange(location: 10, length: 11)
        )

        #expect(result.text == "Keep this ![](a.png)")
        #expect(result.selection == NSRange(location: 20, length: 0))
    }

    @Test("Inserting into empty text works")
    func insertsIntoEmptyText() {
        let result = MarkdownTextInsertion.insert(
            "![](a.png)",
            in: "",
            selection: NSRange(location: 0, length: 0)
        )

        #expect(result.text == "![](a.png)")
        #expect(result.selection == NSRange(location: 10, length: 0))
    }

    /// A selection can outlive the text it was measured against — the other
    /// pane in split view, or a Firestore-style external change, can shorten
    /// the document between the caret moving and the image finishing its copy.
    @Test("A selection past the end is clamped rather than trapping")
    func clampsStaleSelection() {
        let result = MarkdownTextInsertion.insert(
            "X",
            in: "Short",
            selection: NSRange(location: 3, length: 900)
        )

        #expect(result.text == "ShoX")
        #expect(result.selection == NSRange(location: 4, length: 0))
    }

    @Test("A location past the end appends")
    func clampsStaleLocation() {
        let result = MarkdownTextInsertion.insert(
            "!",
            in: "Short",
            selection: NSRange(location: 400, length: 0)
        )

        #expect(result.text == "Short!")
        #expect(result.selection == NSRange(location: 6, length: 0))
    }

    /// The caret is a UTF-16 offset, which is what every AppKit and UIKit text
    /// view means by a location. Counting characters instead would put the
    /// caret before the end of anything outside the basic plane.
    @Test("The caret is measured in UTF-16, not characters")
    func measuresCaretInUTF16() {
        // One extended grapheme cluster; four UTF-16 code units.
        let flag = "🇯🇵🇯🇵"
        #expect(flag.count == 2)

        let result = MarkdownTextInsertion.insert(
            flag,
            in: "ab",
            selection: NSRange(location: 1, length: 0)
        )

        #expect(result.text == "a\(flag)b")
        #expect(result.selection == NSRange(location: 9, length: 0))
    }

    @Test("Inserting into text that already has astral characters")
    func handlesAstralSurroundings() {
        let result = MarkdownTextInsertion.insert(
            "!",
            in: "😀ok",
            selection: NSRange(location: 2, length: 0)
        )

        #expect(result.text == "😀!ok")
        #expect(result.selection == NSRange(location: 3, length: 0))
    }

    @Test("A negative selection is treated as the start")
    func clampsNegativeSelection() {
        let result = MarkdownTextInsertion.insert(
            "X",
            in: "abc",
            selection: NSRange(location: 0, length: 0)
        )

        #expect(result.text == "Xabc")
        #expect(result.selection == NSRange(location: 1, length: 0))
    }
}
