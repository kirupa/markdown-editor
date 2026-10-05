import Testing

@testable import MarkdownEditorCore

/// Counting the words a reader would read.
///
/// The failure that started this: a new document is `# `, a check that only
/// trimmed whitespace let it through as content, and a critique spent a
/// request to score it a hundred out of a hundred.
@Suite("Markdown prose")
struct MarkdownProseTests {
    private func words(_ text: String) -> Int { MarkdownProse.wordCount(text) }

    @Test("A new document has no words in it")
    func newDocument() {
        #expect(words("") == 0)
        #expect(words("# ") == 0)
        #expect(words("#") == 0)
        #expect(words("\n\n   \n") == 0)
    }

    @Test("Heading and paragraph words count, their markers do not")
    func headingsAndParagraphs() {
        #expect(words("# Title\n\nHello world.") == 3)
        #expect(words("###### Six\n\n####### Seven hashes is a paragraph") == 6)
        #expect(words("#hashtag is a word") == 4)
    }

    @Test("Code blocks are not prose")
    func fencedCode() {
        let text = """
            Before the code.

            ```swift
            let answer = compute(42)
            print(answer)
            ```

            ~~~~
            more code here
            ~~~~

            After it.
            """
        #expect(words(text) == 5)
        // An unclosed fence runs to the end, as it renders.
        #expect(words("One two.\n\n```\nlet x = 1\nlet y = 2") == 2)
        // A shorter run of the marker does not close it.
        #expect(words("````\ncode\n```\nstill code\n````\nprose") == 1)
    }

    @Test("A link counts its words, not its address")
    func links() {
        #expect(words("Read [the whole guide](https://example.com/a-b-c) today.") == 5)
        #expect(words("See [Paris](https://en.wikipedia.org/wiki/Paris_(city)) now") == 3)
        #expect(words("A [reference link][guide] here") == 4)
        #expect(words("Bare https://example.com counts once") == 4)
        #expect(words("<https://example.com>") == 1)
    }

    @Test("Images are not words")
    func images() {
        #expect(words("![A diagram of the loop](loop.png)") == 0)
        #expect(words("Look: ![alt words](a.png \"Title words\") done") == 2)
        #expect(words("![alt][ref]") == 0)
    }

    @Test("HTML tags and comments are not words")
    func html() {
        #expect(words("<div class=\"note\">Inside the box</div>") == 3)
        #expect(words("Line one<br/>line two") == 4)
        #expect(words("Seen <!-- not seen --> seen") == 2)
        #expect(words("Seen <!-- not\nseen at\nall --> seen") == 2)
        #expect(words("a < b and c") == 4)
    }

    @Test("List markers, numbers and task boxes are not words")
    func lists() {
        #expect(words("- one\n* two\n+ three") == 3)
        #expect(words("1. first\n2) second\n10. tenth") == 3)
        #expect(words("- [ ] open task\n- [x] done task") == 4)
        #expect(words("> quoted words\n> > nested quote") == 4)
        #expect(words("---\n\n***\n\n___") == 0)
    }

    @Test("Reference definitions and footnotes")
    func references() {
        #expect(words("[guide]: https://example.com \"The guide\"") == 0)
        #expect(words("A claim.[^1]\n\n[^1]: The source for it.") == 6)
    }

    @Test("Table pipes separate cells")
    func tables() {
        let table = """
            | Name | Value |
            |------|-------|
            | a|b |
            """
        #expect(words(table) == 4)
    }

    @Test("Front matter is not prose, but a leading rule is")
    func frontMatter() {
        #expect(words("---\ntitle: A post\ndate: 2024\n---\nHello there.") == 2)
        // A thematic break followed by prose, not a YAML block.
        #expect(words("---\nOpening line.\n---\nMore.") == 3)
        // Unclosed: nothing to skip.
        #expect(words("---\ntitle: never closed") == 3)
    }

    @Test("A word is a run with a letter or digit in it")
    func whatAWordIs() {
        #expect(words("don't state-of-the-art") == 2)
        #expect(words("a — b") == 2)
        #expect(words("It costs $30, or 25%.") == 5)
        #expect(words("**bold** and _italic_ and `code`") == 5)
        #expect(words("Fish&nbsp;and&nbsp;chips &amp; peas") == 4)
    }

    @Test("Scripts written without spaces count each character")
    func ideographs() {
        #expect(words("日本語") == 3)
        #expect(words("日本語。") == 3)
        #expect(words("Hello世界") == 3)
        #expect(words("カタカナ") == 4)
    }

    @Test("Line endings from Windows are spaces")
    func carriageReturns() {
        #expect(words("# Title\r\n\r\nOne two\r\n```\r\ncode\r\n```\r\nthree") == 4)
    }
}
