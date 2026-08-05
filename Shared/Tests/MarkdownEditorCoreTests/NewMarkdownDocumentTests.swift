import Foundation
import Testing

@testable import MarkdownEditorCore

/// A new document starts on a Heading 1 line.
///
/// The text itself is one constant, so what is worth pinning down is the
/// caret: put it at 0 and the first keystroke lands in front of the `#`,
/// which turns the heading into a paragraph and quietly undoes the feature.
@Suite("New document")
struct NewMarkdownDocumentTests {
    @Test("A new document is an empty Heading 1 line")
    func newDocumentStartsAsAnEmptyHeadingOne() {
        #expect(NewMarkdownDocument.text == "# ")
    }

    @Test("A new document is exactly what choosing Heading 1 produces")
    func newDocumentIsWhatChoosingHeadingOneProduces() {
        // The starting text must be reachable by hand, not a special state:
        // applying Heading 1 to an empty document has to give the same bytes,
        // or removing and re-adding the heading would not round-trip.
        let applied = MarkdownFormatting.applyHeading(
            level: 1,
            in: "",
            selection: NSRange(location: 0, length: 0)
        )

        #expect(applied.text == NewMarkdownDocument.text)
    }

    @Test("The caret starts inside the heading, not in front of it")
    func caretStartsInsideTheHeading() {
        let selection = NewMarkdownDocument.initialSelection(
            text: NewMarkdownDocument.text,
            isNewDocument: true
        )

        #expect(selection == NSRange(location: 2, length: 0))
    }

    @Test("An opened file still starts at the beginning")
    func anOpenedFileStartsAtTheBeginning() {
        let selection = NewMarkdownDocument.initialSelection(
            text: "# A saved document\n\nWith prose.\n",
            isNewDocument: false
        )

        #expect(selection == NSRange(location: 0, length: 0))
    }

    @Test("A saved file that merely looks new is left alone")
    func aFileThatMerelyLooksNewStartsAtTheBeginning() {
        // A saved file whose entire contents happen to be "# " is still a
        // file being opened, and opening a file should not move the caret.
        let selection = NewMarkdownDocument.initialSelection(
            text: NewMarkdownDocument.text,
            isNewDocument: false
        )

        #expect(selection == NSRange(location: 0, length: 0))
    }

    @Test("Only the untouched starting text moves the caret")
    func anEditedNewDocumentIsNotRepositioned() {
        let selection = NewMarkdownDocument.initialSelection(
            text: "# Already typed",
            isNewDocument: true
        )

        #expect(selection == NSRange(location: 0, length: 0))
    }

    @Test("Return at the end of the heading starts a body paragraph")
    func returnAtTheEndOfTheHeadingStartsABodyParagraph() {
        // The other half of the requirement, and the half that needed no new
        // code: a heading has nothing to continue, so Return already left it.
        let source = "# Trip notes"

        let result = MarkdownFormatting.insertNewline(
            in: source,
            selection: NSRange(location: (source as NSString).length, length: 0)
        )

        #expect(result.text == "# Trip notes\n")
        #expect(!result.text.hasSuffix("# "))
    }

    @Test("Return from the empty new document leaves the heading behind")
    func returnFromTheEmptyNewDocumentLeavesTheHeading() {
        let result = MarkdownFormatting.insertNewline(
            in: NewMarkdownDocument.text,
            selection: NewMarkdownDocument.initialSelection(
                text: NewMarkdownDocument.text,
                isNewDocument: true
            )
        )

        #expect(result.text == "# \n")
        #expect(result.selection == NSRange(location: 3, length: 0))
    }

    @Test("The new document renders as an empty Heading 1")
    func newDocumentRendersAsAnEmptyHeading() {
        let model = MarkdownRenderer.render(NewMarkdownDocument.text)

        #expect(model.text.isEmpty)
        #expect(model.spans.contains { $0.style == .heading(1) })
    }

    @Test("The new document's caret maps to the start of the rendered heading")
    func newDocumentCaretMapsIntoTheRenderedHeading() {
        let model = MarkdownRenderer.render(NewMarkdownDocument.text)
        let caret = NewMarkdownDocument.initialSelection(
            text: NewMarkdownDocument.text,
            isNewDocument: true
        )

        #expect(model.renderedRange(for: caret) == NSRange(location: 0, length: 0))
        #expect(model.sourceRange(for: NSRange(location: 0, length: 0)) == caret)
    }
}
