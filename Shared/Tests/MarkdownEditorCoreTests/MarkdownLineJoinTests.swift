import Foundation
import MarkdownEditorContract
import Testing
@testable import MarkdownEditorCore

/// What deleting a line break in the rendered view does to the Markdown.
///
/// The bug these were written for: ⌫ on the empty line between a quote and
/// the paragraph under it showed `## ` in the middle of the quote. The empty
/// line was an empty heading, its `## ` hidden, and the edit removed only the
/// line break in front of it — so the marker ended up mid-line, where it is
/// not a heading any more and shows as text.
///
/// Every case is driven the way the editors drive it — a rendered range and
/// what replaces it — and checked against the Markdown that results and where
/// the caret lands, in rendered coordinates, which is what the writer sees.
@Suite("Joining lines in the rendered view")
struct MarkdownLineJoinTests {
    // MARK: - Helpers

    private struct Outcome: Equatable, CustomStringConvertible {
        var source: String
        var caret: Int
        var rendered: String

        var description: String {
            "\(source.debugDescription), caret \(caret), showing \(rendered.debugDescription)"
        }
    }

    /// Replaces a stretch of the rendered text, as the Mac editor does.
    private static func edit(
        _ source: String,
        replacing renderedRange: NSRange,
        with replacement: String
    ) -> Outcome {
        let renderer = MarkdownIncrementalRenderer(source: source)
        let sourceRange = renderer.sourceRange(
            replacing: renderedRange,
            with: replacement
        )
        let edited = (source as NSString).replacingCharacters(
            in: sourceRange,
            with: replacement
        )
        renderer.replace(sourceRange: sourceRange, with: replacement)
        let caret = renderer.renderedRange(
            for: NSRange(
                location: sourceRange.location
                    + (replacement as NSString).length,
                length: 0
            )
        ).location
        return Outcome(
            source: edited,
            caret: caret,
            rendered: renderer.renderedText()
        )
    }

    /// ⌫ with the caret at rendered offset `caret`: the character before it,
    /// or both halves of a CRLF, which `NSTextView` deletes as one —
    /// measured, although `rangeOfComposedCharacterSequence` calls them two.
    private static func deleteBackward(_ source: String, at caret: Int) -> Outcome {
        let rendered = MarkdownRenderer.render(source).text as NSString
        let range = caret >= 2
            && rendered.character(at: caret - 1) == 0x0A
            && rendered.character(at: caret - 2) == 0x0D
            ? NSRange(location: caret - 2, length: 2)
            : rendered.rangeOfComposedCharacterSequence(at: caret - 1)
        return edit(source, replacing: range, with: "")
    }

    /// ⌦ with the caret at rendered offset `caret`.
    private static func deleteForward(_ source: String, at caret: Int) -> Outcome {
        let rendered = MarkdownRenderer.render(source).text as NSString
        let range = caret + 1 < rendered.length
            && rendered.character(at: caret) == 0x0D
            && rendered.character(at: caret + 1) == 0x0A
            ? NSRange(location: caret, length: 2)
            : rendered.rangeOfComposedCharacterSequence(at: caret)
        return edit(source, replacing: range, with: "")
    }

    /// Where `text` starts in the rendered document.
    private static func rendered(_ source: String, find text: String) -> Int {
        let rendered = MarkdownRenderer.render(source).text as NSString
        let found = rendered.range(of: text)
        precondition(found.location != NSNotFound, "\(text) is not shown")
        return found.location
    }

    // MARK: - The report

    /// The shape of the document the bug was reported on.
    private static let reported = """
        > **Note: BFS is the shape of the answer**
        > If BFS rings a bell, it explores every node one edge away before any node two away. \n\
        ## \n\
        Let's run that on our 5-by-5 grid.
        """

    @Test("⌫ on the empty line under a quote puts the caret at the end of the quote, and that is all")
    func backspaceOnEmptyHeadingUnderQuote() {
        let source = Self.reported
        let emptyLine = Self.rendered(source, find: "Let's") - 1
        let outcome = Self.deleteBackward(source, at: emptyLine)

        let expected = """
            > **Note: BFS is the shape of the answer**
            > If BFS rings a bell, it explores every node one edge away before any node two away. \n\
            Let's run that on our 5-by-5 grid.
            """
        #expect(outcome.source == expected)
        #expect(!outcome.rendered.contains("#"))
        // The end of the quote, after its trailing space — which is where
        // the caret was a line break ago.
        #expect(outcome.caret == emptyLine - 1)
        #expect(
            (outcome.rendered as NSString).character(at: outcome.caret) == 0x0A
        )
    }

    @Test("⌦ at the end of the quote does the same")
    func forwardDeleteAtEndOfQuote() {
        let source = Self.reported
        let endOfQuote = Self.rendered(source, find: "Let's") - 2
        let outcome = Self.deleteForward(source, at: endOfQuote)

        #expect(outcome == Self.deleteBackward(source, at: endOfQuote + 1))
        #expect(!outcome.rendered.contains("#"))
        #expect(outcome.caret == endOfQuote)
    }

    @Test("⌫ at the start of the paragraph removes the empty line above it, not the paragraph's style")
    func backspaceAtParagraphUnderEmptyHeading() {
        let source = "> q\n## \nLet's"
        let paragraph = Self.rendered(source, find: "Let's")
        let outcome = Self.deleteBackward(source, at: paragraph)

        #expect(outcome == Outcome(source: "> q\nLet's", caret: 2, rendered: "q\nLet's"))
        #expect(Self.deleteForward(source, at: paragraph - 1) == outcome)
    }

    // MARK: - Joining a line onto the one above

    @Test("A heading joined onto a paragraph carries on the paragraph")
    func headingOntoParagraph() {
        let source = "para\n## Heading"
        let outcome = Self.deleteBackward(
            source,
            at: Self.rendered(source, find: "Heading")
        )
        #expect(outcome == Outcome(source: "paraHeading", caret: 4, rendered: "paraHeading"))
    }

    @Test("A quote line joined onto a quote line stays one quote")
    func quoteOntoQuote() {
        let source = "> one\n> two"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "two"))
        #expect(outcome == Outcome(source: "> onetwo", caret: 3, rendered: "onetwo"))
    }

    @Test("A heading joined onto a heading stays one heading")
    func headingOntoHeading() {
        let source = "## A\n### B"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "B"))
        #expect(outcome == Outcome(source: "## AB", caret: 1, rendered: "AB"))
    }

    @Test("A paragraph joined onto a heading takes the heading's style")
    func paragraphOntoHeading() {
        let source = "## Title\nLet's"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "Let's"))
        #expect(outcome.source == "## TitleLet's")
    }

    @Test("Only the marker goes: a bold word on the joined line stays bold")
    func hiddenInlineMarkupIsKept() {
        let source = "para\n## **Bold**"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "Bold"))
        #expect(outcome == Outcome(source: "para**Bold**", caret: 4, rendered: "paraBold"))
    }

    @Test("Hashes that were shown as text are text")
    func escapedHashesStay() {
        let source = "para\n\\## x"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "## x"))
        #expect(outcome.source == "para\\## x")
        #expect(outcome.rendered == "para## x")
    }

    @Test("A line inside a fence is code, so its hashes are code")
    func codeLinesAreNotMarkers() {
        let source = "```\none\n## code\n```"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "## code"))
        #expect(outcome.source == "```\none## code\n```")
    }

    @Test("An empty heading at the very end goes with the line break before it")
    func trailingEmptyHeading() {
        let source = "para\n## "
        let outcome = Self.deleteBackward(source, at: 5)
        #expect(outcome == Outcome(source: "para", caret: 4, rendered: "para"))
    }

    @Test("CRLF line endings join the same way")
    func crlf() {
        let source = "> q\r\n## \r\nLet's"
        let paragraph = Self.rendered(source, find: "Let's")
        let joined = Self.deleteBackward(source, at: paragraph - 2)
        #expect(joined == Outcome(source: "> q\r\nLet's", caret: 1, rendered: "q\r\nLet's"))
        #expect(Self.deleteForward(source, at: 1) == joined)

        let removed = Self.deleteBackward(source, at: paragraph)
        #expect(removed == Outcome(source: "> q\r\nLet's", caret: 3, rendered: "q\r\nLet's"))
    }

    /// ← parks the caret between a CRLF's halves, so half of one can go.
    /// What is left is still a line break, so nothing is joined and the
    /// empty heading stays where it was.
    @Test("Deleting only the \\n of a CRLF joins nothing")
    func halfACRLF() {
        let source = "> q\r\n## \r\nLet's"
        let outcome = Self.edit(
            source,
            replacing: NSRange(location: 2, length: 1),
            with: ""
        )
        #expect(outcome.source == "> q\r## \r\nLet's")
        #expect(!outcome.rendered.contains("#"))
    }

    @Test("Typing over a selection that ends in a line break joins the same way")
    func typingOverALineBreak() {
        let source = "> q\n## \nLet's"
        let outcome = Self.edit(
            source,
            replacing: NSRange(location: 0, length: 2),
            with: "x"
        )
        #expect(outcome == Outcome(source: "> x\nLet's", caret: 1, rendered: "x\nLet's"))
    }

    // MARK: - Deleting whole lines

    @Test("⌫ on an empty line under a paragraph leaves the heading below it a heading")
    func emptyLineAboveHeading() {
        let source = "para\n\n## H"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "H"))
        #expect(outcome == Outcome(source: "para\n## H", caret: 5, rendered: "para\nH"))
    }

    @Test("An empty quote line goes whole, and the heading under it stays a heading")
    func emptyQuoteAboveHeading() {
        let source = ">\n## H"
        let outcome = Self.deleteBackward(source, at: Self.rendered(source, find: "H"))
        #expect(outcome == Outcome(source: "## H", caret: 0, rendered: "H"))
    }

    @Test("An empty heading at the top goes whole")
    func emptyHeadingAtTop() {
        let source = "## \nText"
        let outcome = Self.deleteBackward(source, at: 1)
        #expect(outcome == Outcome(source: "Text", caret: 0, rendered: "Text"))
    }

    @Test("Deleting a selected heading line takes its marker with it")
    func deletingASelectedLine() {
        let source = "## Title\nLet's"
        let outcome = Self.edit(
            source,
            replacing: NSRange(location: 0, length: 6),
            with: ""
        )
        #expect(outcome == Outcome(source: "Let's", caret: 0, rendered: "Let's"))
    }

    @Test("Deleting the line under a fence leaves the fence closed")
    func fenceAboveIsKept() {
        let source = "```\ncode\n```\n## H\nnext"
        let line = Self.rendered(source, find: "H")
        let outcome = Self.edit(
            source,
            replacing: NSRange(location: line, length: 2),
            with: ""
        )
        #expect(outcome.source == "```\ncode\n```\nnext")
    }

    @Test("Deleting part of a line leaves an empty heading behind, as a word processor does")
    func deletingAllTheWordsKeepsTheLine() {
        let source = "para\n## Title"
        let outcome = Self.edit(
            source,
            replacing: NSRange(location: 5, length: 5),
            with: ""
        )
        #expect(outcome.source == "para\n## ")
    }

    // MARK: - What is left alone

    /// Everything that does not remove a line break maps exactly as it did,
    /// over a document with every block construct in it.
    @Test("Edits that keep their line breaks map as they always did")
    func otherEditsAreUnchanged() {
        let source = """
            # Title
            > a quote with **bold**
            >
            ## \n\
            - item
            - [ ] task
            1. one
            ---
            ```swift
            let x = 1
            ```
            Paragraph with ![alt](a.png) and `code`.
            """
        let renderer = MarkdownIncrementalRenderer(source: source)
        let rendered = renderer.renderedText() as NSString
        for location in 0...rendered.length {
            for length in 0...min(3, rendered.length - location) {
                let range = NSRange(location: location, length: length)
                let base = renderer.sourceRange(for: range)
                // Return, and anything ending in a line break, is never
                // adjusted.
                #expect(renderer.sourceRange(replacing: range, with: "\n") == base)
                #expect(renderer.sourceRange(replacing: range, with: "a\n") == base)
                let endsALine = length > 0
                    && [0x0A, 0x0D].contains(rendered.character(at: location + length - 1))
                if !endsALine {
                    #expect(renderer.sourceRange(replacing: range, with: "") == base)
                    #expect(renderer.sourceRange(replacing: range, with: "x") == base)
                }
            }
        }
    }

    // MARK: - Across the corpus

    /// The contract documents and the ones written for editing — the same
    /// set, and the same edits, that `Contract/edits.jsonl` is dumped from.
    private static let corpus = ContractCorpus.documents + ContractCorpus.editingDocuments

    private static func lineEdits(
        in document: ContractCorpus.Document
    ) -> (MarkdownIncrementalRenderer, NSString, [ContractCorpus.LineEdit]) {
        let renderer = MarkdownIncrementalRenderer(source: document.text)
        let rendered = renderer.renderedText() as NSString
        return (renderer, rendered, ContractCorpus.lineEdits(inRendered: rendered))
    }

    @Test("Every line-break edit takes at least what was selected, and nothing outside the document")
    func everyEditIsWellFormed() {
        var count = 0
        for document in Self.corpus {
            let (renderer, _, edits) = Self.lineEdits(in: document)
            let length = (document.text as NSString).length
            for edit in edits {
                let base = renderer.sourceRange(for: edit.range)
                let range = renderer.sourceRange(replacing: edit.range, with: edit.replacement)
                let label = "\(document.id) \(edit.kind) at \(edit.range)"
                #expect(range.location >= 0 && NSMaxRange(range) <= length, "\(label)")
                #expect(range.location <= base.location, "\(label)")
                #expect(NSMaxRange(range) >= NSMaxRange(base), "\(label)")

                // The incremental path the editors take agrees with a full
                // render of the same Markdown.
                let incremental = MarkdownIncrementalRenderer(source: document.text)
                incremental.replace(sourceRange: range, with: edit.replacement)
                let edited = (document.text as NSString)
                    .replacingCharacters(in: range, with: edit.replacement)
                #expect(
                    incremental.renderedText() == MarkdownRenderer.render(edited).text,
                    "\(label)"
                )
                count += 1
            }
        }
        #expect(count > 250)
    }

    /// Deleting lines from the start of one to the start of the next shows
    /// exactly the lines that were not deleted — on every document, whatever
    /// the lines hid.
    @Test("Deleting a whole line leaves exactly the other lines showing")
    func deletingALineIsWhatYouSee() {
        for document in Self.corpus {
            let (renderer, rendered, edits) = Self.lineEdits(in: document)
            for edit in edits where edit.kind == "deleteLine" {
                let range = renderer.sourceRange(replacing: edit.range, with: "")
                let edited = (document.text as NSString)
                    .replacingCharacters(in: range, with: "")
                #expect(
                    MarkdownRenderer.render(edited).text
                        == rendered.replacingCharacters(in: edit.range, with: ""),
                    "\(document.id) deleting \(edit.range)"
                )
            }
        }
    }

    /// Joining two lines shows exactly the two lines joined — wherever that
    /// is a fair thing to ask. Not across a fence, whose hidden lines are not
    /// part of either line, and not where inline Markdown could pair up
    /// differently once the lines are one, which is Markdown being Markdown
    /// rather than the edit going wrong.
    @Test("Joining two plain lines shows exactly the two lines joined")
    func joiningPlainLinesIsWhatYouSee() {
        var checked = 0
        for document in Self.corpus {
            let (renderer, rendered, edits) = Self.lineEdits(in: document)
            let source = document.text as NSString
            for edit in edits where edit.kind != "deleteLine" {
                let below = NSMaxRange(edit.range)
                let above = rendered.lineRange(
                    for: NSRange(location: edit.range.location, length: 0)
                ).location
                let belowEnd = below == rendered.length
                    ? below
                    : NSMaxRange(rendered.lineRange(for: NSRange(location: below, length: 0)))
                let pair = NSRange(location: above, length: belowEnd - above)
                let lines = source.lineRange(for: renderer.sourceRange(for: pair))
                let gap = NSRange(
                    location: NSMaxRange(renderer.sourceRange(for: edit.range)),
                    length: 0
                )
                let hidden = NSRange(
                    location: gap.location,
                    length: renderer.sourceRange(for: NSRange(location: below, length: 0))
                        .location - gap.location
                )
                guard
                    source.substring(with: lines)
                        .rangeOfCharacter(from: CharacterSet(charactersIn: "*_~`[]!<\\")) == nil,
                    rendered.substring(with: pair)
                        .rangeOfCharacter(from: CharacterSet(charactersIn: "•☐☑—\u{FFFC}")) == nil,
                    source.substring(with: hidden)
                        .rangeOfCharacter(from: .newlines) == nil
                else {
                    continue
                }

                let range = renderer.sourceRange(replacing: edit.range, with: edit.replacement)
                let edited = source.replacingCharacters(in: range, with: edit.replacement)
                #expect(
                    MarkdownRenderer.render(edited).text
                        == rendered.replacingCharacters(in: edit.range, with: edit.replacement),
                    "\(document.id) \(edit.kind) at \(edit.range)"
                )
                checked += 1
            }
        }
        #expect(checked > 80)
    }

    @Test("The marker the parser hides is exactly the marker removed")
    func markerLengthMatchesTheParser() {
        let cases: [(String, Int)] = [
            ("## Title", 3),
            ("#\tTitle", 2),
            ("   ### Title", 7),
            ("####### seven", 0),
            ("##Title", 0),
            ("##", 0),
            ("## ", 3),
            ("> quote", 2),
            (">quote", 1),
            ("  >  two spaces", 4),
            ("text", 0),
            ("\\## escaped", 0),
        ]
        for (line, expected) in cases {
            let source = "x\n\(line)\ny" as NSString
            #expect(
                MarkdownLinePrefix.hiddenLength(in: source, lineStart: 2) == expected,
                "\(line.debugDescription)"
            )
        }
    }
}
