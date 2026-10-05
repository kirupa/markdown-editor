import Foundation
import Testing

@testable import MarkdownEditorCore

/// What the title bar says about a draft's length.
@Suite("Document length")
struct DocumentLengthTests {
    private let english = Locale(identifier: "en_US")

    private func summary(_ text: String, selection: NSRange? = nil) -> String {
        DocumentLength(text: text, selection: selection).summary(locale: english)
    }

    @Test("Words and a reading time, the way the title bar says them")
    func summaries() {
        #expect(summary("") == "0 words")
        #expect(summary("# ") == "0 words")
        #expect(summary("Hello.") == "1 word · 1 min read")
        #expect(summary("# Title\n\nHello world.") == "3 words · 1 min read")
        #expect(
            DocumentLength(words: 21_537).summary(locale: english)
                == "21,537 words · 91 min read"
        )
    }

    @Test("Reading time rounds up, so a sentence is never no time at all")
    func readingMinutes() {
        #expect(DocumentLength(words: 0).readingMinutes == 0)
        #expect(DocumentLength(words: 1).readingMinutes == 1)
        #expect(DocumentLength(words: 238).readingMinutes == 1)
        #expect(DocumentLength(words: 239).readingMinutes == 2)
        #expect(DocumentLength(words: 600).readingMinutes == 3)
    }

    @Test("It is the count the critique uses, Markdown left out")
    func sameCountAsTheCritique() {
        let draft = """
            ---
            title: Front matter is not read
            ---

            # A heading

            A [link](https://example.com/a/long/address) and some prose.

            ```swift
            let code = "is not prose either"
            ```
            """
        #expect(DocumentLength(text: draft).words == MarkdownProse.wordCount(draft))
        #expect(DocumentLength(text: draft).words == 7)
    }

    @Test("A selection with words in it is counted on its own")
    func selection() {
        let text = "One two three four five."
        #expect(summary(text, selection: NSRange(location: 4, length: 9)) == "2 of 5 words")
        #expect(summary(text, selection: NSRange(location: 0, length: 24)) == "5 of 5 words")
        #expect(summary("Hello.", selection: NSRange(location: 0, length: 6)) == "1 of 1 word")
    }

    @Test("A caret, or a selection of nothing a reader reads, is no selection")
    func emptySelections() {
        let text = "# Title\n\nOne two."
        #expect(summary(text, selection: NSRange(location: 3, length: 0)) == "3 words · 1 min read")
        // "# " and the blank line: marks and spaces, no words.
        #expect(summary(text, selection: NSRange(location: 0, length: 2)) == "3 words · 1 min read")
        #expect(summary(text, selection: NSRange(location: 7, length: 2)) == "3 words · 1 min read")
    }

    @Test("A selection left over from a longer draft is clamped, not trusted")
    func staleSelection() {
        let text = "Short now."
        #expect(summary(text, selection: NSRange(location: 6, length: 400)) == "1 of 2 words")
        #expect(summary(text, selection: NSRange(location: 400, length: 10)) == "2 words · 1 min read")
        #expect(summary(text, selection: NSRange(location: -3, length: 2)) == "2 words · 1 min read")
    }
}
