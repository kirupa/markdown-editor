import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Markdown text difference")
struct MarkdownTextDifferenceTests {
    @Test("Anchored insertion wins when text repeats")
    func anchoredInsertionWinsWithRepeatedText() {
        let atStart = MarkdownTextDifference.replacement(
            from: "aa",
            to: "aaa",
            replacing: NSRange(location: 0, length: 0)
        )
        let atEnd = MarkdownTextDifference.replacement(
            from: "aa",
            to: "aaa",
            replacing: NSRange(location: 2, length: 0)
        )

        #expect(
            atStart == MarkdownTextReplacement(
                range: NSRange(location: 0, length: 0),
                replacement: "a"
            )
        )
        #expect(
            atEnd == MarkdownTextReplacement(
                range: NSRange(location: 2, length: 0),
                replacement: "a"
            )
        )
    }

    @Test("Anchored replacement preserves surrounding repeated text")
    func anchoredReplacementPreservesContext() {
        let replacement = MarkdownTextDifference.replacement(
            from: "same same",
            to: "same SAME",
            replacing: NSRange(location: 5, length: 4)
        )

        #expect(
            replacement == MarkdownTextReplacement(
                range: NSRange(location: 5, length: 4),
                replacement: "SAME"
            )
        )
    }

    @Test("Difference falls back when surrounding text changed")
    func differenceFallsBackWhenAnchorDoesNotMatch() {
        let replacement = MarkdownTextDifference.replacement(
            from: "before",
            to: "after",
            replacing: NSRange(location: 3, length: 0)
        )

        #expect(replacement.range == NSRange(location: 0, length: 6))
        #expect(replacement.replacement == "after")
    }

    // MARK: - Mapping a selection across a reload

    @Test("A caret before the change keeps its place")
    func caretBeforeChangeIsUnmoved() {
        let mapped = MarkdownTextDifference.mappedSelection(
            NSRange(location: 3, length: 0),
            from: "hello world",
            to: "hello there world"
        )
        #expect(mapped == NSRange(location: 3, length: 0))
    }

    /// The case that matters most: somebody reading far down a document while
    /// another app rewrites the top of it should stay where they were reading.
    @Test("A caret after the change keeps its distance from the end")
    func caretAfterChangeFollowsTheTail() {
        let mapped = MarkdownTextDifference.mappedSelection(
            NSRange(location: 9, length: 0),
            from: "intro\nbody tail",
            to: "a much longer intro\nbody tail"
        )
        // Four characters from the end in both.
        #expect(mapped.location == ("a much longer intro\nbody tail" as NSString).length - 6)
        #expect(mapped.length == 0)
    }

    @Test("A caret inside the change lands at the end of it")
    func caretInsideChangeCollapsesToItsEnd() {
        let mapped = MarkdownTextDifference.mappedSelection(
            NSRange(location: 3, length: 0),
            from: "aaXXaa",
            to: "aaYYYYaa"
        )
        #expect(mapped == NSRange(location: 6, length: 0))
    }

    @Test("A selection outside the change keeps its length")
    func selectionOutsideChangeKeepsLength() {
        let mapped = MarkdownTextDifference.mappedSelection(
            NSRange(location: 0, length: 5),
            from: "hello world",
            to: "hello brave world"
        )
        #expect(mapped == NSRange(location: 0, length: 5))
    }

    @Test("Identical text leaves the selection exactly as it was")
    func identicalTextIsAnIdentity() {
        let text = "# Title\n\nSome body text.\n"
        for location in 0...(text as NSString).length {
            let range = NSRange(location: location, length: 0)
            #expect(
                MarkdownTextDifference.mappedSelection(
                    range,
                    from: text,
                    to: text
                ) == range
            )
        }
    }

    /// A mapped selection is only useful if it can actually be applied, so the
    /// invariant worth stating is that it always lands inside the new text.
    @Test("A mapped selection always fits the new text")
    func mappedSelectionAlwaysFits() {
        let samples = ["", "a", "abc", "hello world", "line\nline\nline"]
        for old in samples {
            for new in samples {
                let oldLength = (old as NSString).length
                let newLength = (new as NSString).length
                for location in 0...oldLength {
                    for length in 0...(oldLength - location) {
                        let mapped = MarkdownTextDifference.mappedSelection(
                            NSRange(location: location, length: length),
                            from: old,
                            to: new
                        )
                        #expect(mapped.location >= 0)
                        #expect(mapped.length >= 0)
                        #expect(
                            NSMaxRange(mapped) <= newLength,
                            "\(old) -> \(new) at \(location)/\(length)"
                        )
                    }
                }
            }
        }
    }

    /// Deleting everything has nowhere to put a caret but the start, and must
    /// not produce a negative offset on the way there.
    @Test("Mapping into an empty document collapses to the start")
    func mappingIntoEmptyDocument() {
        let mapped = MarkdownTextDifference.mappedSelection(
            NSRange(location: 7, length: 3),
            from: "some longer text",
            to: ""
        )
        #expect(mapped == NSRange(location: 0, length: 0))
    }
}
