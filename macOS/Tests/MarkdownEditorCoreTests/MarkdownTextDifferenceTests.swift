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
}
