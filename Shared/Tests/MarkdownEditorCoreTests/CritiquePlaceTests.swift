import Foundation
import Testing

@testable import MarkdownEditorCore

/// The place printed on a critique note is worked out from the draft, not
/// copied from the critic, so the same paragraph is named the same way on
/// every run — the critic called one paragraph "Opening, paragraph 2" on one
/// read and "Opening, paragraph 1" on the next.
@Suite("Naming where a critique note is")
struct CritiquePlaceTests {
    private func label(_ text: String, at quote: String) -> String? {
        let range = (text as NSString).range(of: quote)
        precondition(range.location != NSNotFound, "\(quote) is not in the draft")
        return CritiqueOutline(text).place(of: range)?.label
    }

    private let essay = """
        # Caching

        Every request starts somewhere.

        The cache keeps the answer.

        ## Why it matters

        A miss costs a round trip.
        """

    // MARK: - Sections and paragraphs

    @Test("The title is not a paragraph")
    func titleIsNotCounted() {
        // The disagreement the critic kept having with itself.
        #expect(label(essay, at: "Every request") == "Opening · paragraph 1")
        #expect(label(essay, at: "The cache keeps") == "Opening · paragraph 2")
        #expect(label(essay, at: "Caching") == "Title")
    }

    @Test("A paragraph is counted from its own section's heading")
    func sectionsRestartTheCount() {
        #expect(label(essay, at: "A miss") == "Why it matters · paragraph 1")
        #expect(label(essay, at: "Why it matters") == "Why it matters · heading")
    }

    @Test("A draft with no sections has no opening either")
    func unsectionedDrafts() {
        #expect(label("# Notes\n\nOne.\n\nTwo.", at: "Two.") == "Paragraph 2")
        #expect(label("One.\n\nTwo.", at: "One.") == "Paragraph 1")
    }

    @Test("Before the first heading of an untitled draft is the opening")
    func untitledOpening() {
        let draft = "Straight in.\n\n## Setup\n\nThen this."
        #expect(label(draft, at: "Straight in.") == "Opening · paragraph 1")
        #expect(label(draft, at: "Then this.") == "Setup · paragraph 1")
    }

    @Test("Only a first-line level-one heading is the title")
    func whatCountsAsTheTitle() {
        #expect(label("## Setup\n\nText.", at: "Setup") == "Setup · heading")
        #expect(label("## Setup\n\nText.", at: "Text.") == "Setup · paragraph 1")
        let twoTops = "# Title\n\nA.\n\n# Part two\n\nB."
        #expect(label(twoTops, at: "B.") == "Part two · paragraph 1")
        #expect(label(twoTops, at: "Title") == "Title")
    }

    @Test("A paragraph added above renames the ones below it")
    func followsTheDraft() {
        let before = "## Setup\n\nInstall it."
        let after = "## Setup\n\nFirst, a word.\n\nInstall it."
        #expect(label(before, at: "Install it.") == "Setup · paragraph 1")
        #expect(label(after, at: "Install it.") == "Setup · paragraph 2")
    }

    @Test("A passage that starts in the gap belongs to the block it reaches")
    func passageStartingInWhitespace() {
        let text = essay as NSString
        let paragraph = text.range(of: "The cache keeps")
        let fromTheGap = NSRange(location: paragraph.location - 1, length: 10)
        #expect(
            CritiqueOutline(essay).place(of: fromTheGap)?.label
                == "Opening · paragraph 2"
        )
    }

    // MARK: - Lists, quotes and code

    @Test("A list is named as a list, and does not count as a paragraph")
    func lists() {
        let draft = "## Steps\n\nIntro.\n\n- one\n- two\n\nAfter."
        #expect(label(draft, at: "two") == "Steps · list")
        #expect(label(draft, at: "After.") == "Steps · paragraph 2")
    }

    @Test("A loose list is one list")
    func looseLists() {
        let draft = "## Steps\n\n- one\n\n- two\n\n\n- three"
        #expect(label(draft, at: "three") == "Steps · list")
        // And an item's second paragraph, indented under it, is the item's.
        let continued = "## Steps\n\n- one\n\n  more about one\n\nAfter."
        #expect(label(continued, at: "more about") == "Steps · list")
        #expect(label(continued, at: "After.") == "Steps · paragraph 1")
    }

    @Test("Lists are numbered when a section has more than one")
    func severalLists() {
        let draft = "## Steps\n\n- a\n- b\n\nMiddle.\n\n1. c\n2. d"
        #expect(label(draft, at: "- a") == "Steps · list 1")
        #expect(label(draft, at: "2. d") == "Steps · list 2")
        // A numbered list straight after a bulleted one is a second list.
        let switched = "## Steps\n\n- a\n\n1. b"
        #expect(label(switched, at: "1. b") == "Steps · list 2")
    }

    @Test("A list line interrupts a paragraph, as it does on the page")
    func listInterruptsParagraph() {
        let draft = "## S\n\nHere are options:\n- one\n- two\nThen more."
        #expect(label(draft, at: "Here are") == "S · paragraph 1")
        #expect(label(draft, at: "two") == "S · list")
        #expect(label(draft, at: "Then more.") == "S · paragraph 2")
    }

    @Test("Quotes and code are named for what they are")
    func quotesAndCode() {
        let draft = "## S\n\n> quoted\n> more\n\n```\n# not a heading\n```\n\nPara."
        #expect(label(draft, at: "more") == "S · quote")
        #expect(label(draft, at: "not a heading") == "S · code block")
        // A heading inside a fence is code, not a new section.
        #expect(label(draft, at: "Para.") == "S · paragraph 1")
    }

    @Test("An unclosed fence runs to the end of the draft")
    func unclosedFence() {
        let draft = "## S\n\n```\ncode\n\n## Not a section\n\nstill code"
        #expect(label(draft, at: "still code") == "S · code block")
    }

    @Test("A rule separates paragraphs without being one")
    func rules() {
        let draft = "## S\n\nA.\n\n---\n\nB.\n\n- - -\nC."
        #expect(label(draft, at: "B.") == "S · paragraph 2")
        #expect(label(draft, at: "C.") == "S · paragraph 3")
    }

    @Test("Front matter is set aside, so the heading under it is the title")
    func frontMatter() {
        let draft = "---\ntitle: Caching\n---\n# Caching\n\nPara."
        #expect(label(draft, at: "Para.") == "Paragraph 1")
        #expect(label(draft, at: "# Caching") == "Title")
        // Unclosed, it is a rule and a paragraph like any other.
        let unclosed = "---\ntitle: Caching\n\nPara."
        #expect(label(unclosed, at: "Para.") == "Paragraph 2")
    }

    // MARK: - Section names

    @Test("A section is named the way its heading looks")
    func headingMarkupIsTakenOut() {
        let marked = "## **Why** `caching` [matters](https://example.com) ##\n\nText."
        #expect(label(marked, at: "Text.") == "Why caching matters · paragraph 1")
        let underscores = "## Use snake_case _names_\n\nText."
        #expect(label(underscores, at: "Text.") == "Use snake_case names · paragraph 1")
        let escaped = "## Escaped \\*star\\*\n\nText."
        #expect(label(escaped, at: "Text.") == "Escaped *star* · paragraph 1")
        #expect(label("## \n\nText.", at: "Text.") == "Untitled section · paragraph 1")
    }

    @Test("A long heading is cut at a word")
    func longHeadings() {
        let draft = "## The surprisingly long history of caching layers\n\nText."
        #expect(
            label(draft, at: "Text.")
                == "The surprisingly long history of… · paragraph 1"
        )
        let unbroken = "## " + String(repeating: "a", count: 40) + "\n\nText."
        #expect(
            label(unbroken, at: "Text.")
                == String(repeating: "a", count: 32) + "… · paragraph 1"
        )
    }

    // MARK: - When to look again

    private func mayMove(_ old: String, _ new: String) -> Bool {
        let edit = CritiqueAnchorTracking.edit(from: old, to: new)!
        return CritiqueOutline.mayMovePlaces(from: old, to: new, through: edit)
    }

    @Test("Typing inside a paragraph or an item moves nothing")
    func ordinaryTyping() {
        #expect(!mayMove("## S\n\nThe cache.", "## S\n\nThe caches."))
        #expect(!mayMove("## S\n\n- one item", "## S\n\n- one items"))
        #expect(!mayMove("Plain.\n\nAnother.", "Plain.\n\nAnother one."))
    }

    @Test("Breaking or joining lines may move every note below")
    func lineBreaks() {
        #expect(mayMove("A.\n\nB.", "A.\n\n\nB."))
        #expect(mayMove("A.\n\nB.", "A.\nB."))
        #expect(mayMove("A. B.", "A.\u{2028}B."))
    }

    @Test("A line that changes what it is may move them")
    func lineKinds() {
        #expect(mayMove("A.\n\nText.", "A.\n\n# Text."))
        #expect(mayMove("A.\n\n-Text.", "A.\n\n- Text."))
        #expect(mayMove("A.\n\nT", "A.\n\n"))
        #expect(mayMove("A.\n\n--", "A.\n\n---"))
    }

    @Test("A heading's own words rename the notes under it")
    func headingWords() {
        #expect(mayMove("## Setu\n\nText.", "## Setup\n\nText."))
    }

    @Test("A key under an opening rule can make front matter")
    func frontMatterKeys() {
        #expect(mayMove("---\ntitle\n---\n\nText.", "---\ntitle:\n---\n\nText."))
        #expect(!mayMove("Title line\nnext\n\nText.", "Title lines\nnext\n\nText."))
    }
}
