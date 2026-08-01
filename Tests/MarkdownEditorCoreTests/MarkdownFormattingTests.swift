import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Markdown formatting")
struct MarkdownFormattingTests {
    @Test("Inline styles wrap Unicode selection")
    func inlineStylesWrapUnicodeSelection() {
        let text = "Use 🌱 here"
        let selection = (text as NSString).range(of: "🌱")

        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: text,
            selection: selection
        )

        #expect(result.text == "Use **🌱** here")
        #expect(
            (result.text as NSString).substring(with: result.selection) == "🌱"
        )
    }

    @Test("Inline style toggles off around selected content")
    func inlineStyleTogglesOff() {
        let text = "Use **bold** here"
        let selection = (text as NSString).range(of: "bold")

        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: text,
            selection: selection
        )

        #expect(result.text == "Use bold here")
        #expect(result.selection == NSRange(location: 4, length: 4))
    }

    @Test("Empty inline selection inserts a selected placeholder")
    func emptyInlineSelectionInsertsPlaceholder() {
        let result = MarkdownFormatting.toggleInline(
            .italic,
            in: "hello",
            selection: NSRange(location: 5, length: 0)
        )

        #expect(result.text == "hello*italic text*")
        #expect(result.selection == NSRange(location: 6, length: 11))
    }

    @Test("Empty bold insertion is not a thematic break")
    func emptyBoldInsertionIsNotRule() {
        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: "",
            selection: NSRange(location: 0, length: 0)
        )

        #expect(result.text == "**bold text**")
        #expect(MarkdownRenderer.render(result.text).text == "bold text")
    }

    @Test("Italic combines with a fully selected bold token")
    func italicCombinesWithBold() {
        let result = MarkdownFormatting.toggleInline(
            .italic,
            in: "**bold**",
            selection: NSRange(location: 0, length: 8)
        )

        #expect(result.text == "***bold***")
    }

    @Test("Combined bold and italic toggle independently")
    func combinedStylesToggleOffIndependently() {
        let italicOff = MarkdownFormatting.toggleInline(
            .italic,
            in: "***bold***",
            selection: NSRange(location: 0, length: 10)
        )
        let boldOff = MarkdownFormatting.toggleInline(
            .bold,
            in: "***bold***",
            selection: NSRange(location: 0, length: 10)
        )

        #expect(italicOff.text == "**bold**")
        #expect(boldOff.text == "*bold*")
    }

    @Test("Combined styles toggle from content-only selection")
    func combinedStylesToggleFromRenderedSelection() {
        let italicOff = MarkdownFormatting.toggleInline(
            .italic,
            in: "***bold***",
            selection: NSRange(location: 3, length: 4)
        )
        let boldOff = MarkdownFormatting.toggleInline(
            .bold,
            in: "___bold___",
            selection: NSRange(location: 3, length: 4)
        )

        #expect(italicOff.text == "**bold**")
        #expect(boldOff.text == "_bold_")
    }

    @Test("Underscore styles toggle off")
    func underscoreStylesToggleOff() {
        let italic = MarkdownFormatting.toggleInline(
            .italic,
            in: "_word_",
            selection: NSRange(location: 0, length: 6)
        )
        let bold = MarkdownFormatting.toggleInline(
            .bold,
            in: "__word__",
            selection: NSRange(location: 0, length: 8)
        )
        let combined = MarkdownFormatting.toggleInline(
            .italic,
            in: "___word___",
            selection: NSRange(location: 0, length: 10)
        )

        #expect(italic.text == "word")
        #expect(bold.text == "word")
        #expect(combined.text == "__word__")
    }

    @Test("Emphasis keeps selected boundary whitespace outside markers")
    func emphasisKeepsBoundaryWhitespaceOutside() {
        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: "word ",
            selection: NSRange(location: 0, length: 5)
        )

        #expect(result.text == "**word** ")
        #expect(MarkdownRenderer.render(result.text).text == "word ")
    }

    @Test("Inline code round trips meaningful boundary spaces")
    func inlineCodeRoundTripsBoundarySpaces() {
        let text = " foo "
        let wrapped = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: NSRange(location: 0, length: 5)
        )
        let unwrapped = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: wrapped.text,
            selection: NSRange(
                location: 0,
                length: (wrapped.text as NSString).length
            )
        )

        #expect(MarkdownRenderer.render(wrapped.text).text == text)
        #expect(unwrapped.text == text)

        let renderedToggle = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: wrapped.text,
            selection: wrapped.selection
        )
        #expect(renderedToggle.text == text)
    }

    @Test("Heading replaces an existing heading marker")
    func headingReplacesExistingMarker() {
        let result = MarkdownFormatting.applyHeading(
            level: 3,
            in: "## Heading\nBody",
            selection: NSRange(location: 4, length: 0)
        )

        #expect(result.text == "### Heading\nBody")
        #expect(result.selection == NSRange(location: 5, length: 0))
    }

    @Test("Heading applies to an empty final line")
    func headingAppliesToEmptyFinalLine() {
        let result = MarkdownFormatting.applyHeading(
            level: 2,
            in: "Body\n",
            selection: NSRange(location: 5, length: 0)
        )

        #expect(result.text == "Body\n## ")
        #expect(result.selection == NSRange(location: 8, length: 0))
    }

    @Test("Bulleted list applies to every selected line")
    func bulletedListAppliesToSelectedLines() {
        let text = "one\ntwo\nthree"
        let result = MarkdownFormatting.toggleList(
            .bulleted,
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        #expect(result.text == "- one\n- two\n- three")
        #expect(
            (result.text as NSString).substring(with: result.selection)
                == "one\n- two\n- three"
        )
    }

    @Test("Bulleted list toggles off")
    func bulletedListTogglesOff() {
        let text = "- one\n- two"
        let result = MarkdownFormatting.toggleList(
            .bulleted,
            in: text,
            selection: NSRange(location: 2, length: 7)
        )

        #expect(result.text == "one\ntwo")
    }

    @Test("Numbered list replaces other list markers")
    func numberedListReplacesOtherMarkers() {
        let text = "- one\n- two"
        let result = MarkdownFormatting.toggleList(
            .numbered,
            in: text,
            selection: NSRange(location: 0, length: (text as NSString).length)
        )

        #expect(result.text == "1. one\n2. two")
    }

    @Test("Task list adds checkboxes")
    func taskListAddsCheckboxes() {
        let result = MarkdownFormatting.toggleList(
            .task,
            in: "one\ntwo",
            selection: NSRange(location: 0, length: 7)
        )

        #expect(result.text == "- [ ] one\n- [ ] two")
    }

    @Test("Quote toggles selected lines")
    func quoteTogglesSelectedLines() {
        let text = "one\ntwo"
        let quoted = MarkdownFormatting.toggleQuote(
            in: text,
            selection: NSRange(location: 0, length: 7)
        )
        let unquoted = MarkdownFormatting.toggleQuote(
            in: quoted.text,
            selection: NSRange(
                location: 2,
                length: (quoted.text as NSString).length - 2
            )
        )

        #expect(quoted.text == "> one\n> two")
        #expect(unquoted.text == text)
    }

    @Test("Code block wraps and selects original content")
    func codeBlockWrapsContent() {
        let result = MarkdownFormatting.wrapCodeBlock(
            in: "let value = 1",
            selection: NSRange(location: 0, length: 13)
        )

        #expect(result.text == "```\nlet value = 1\n```")
        #expect(
            (result.text as NSString).substring(with: result.selection)
                == "let value = 1"
        )
    }

    @Test("Code block expands a partial selection to full lines")
    func codeBlockExpandsToFullLines() {
        let text = "before\nselected text\nafter"
        let selection = (text as NSString).range(of: "text")
        let result = MarkdownFormatting.wrapCodeBlock(
            in: text,
            selection: selection
        )

        #expect(result.text == "before\n```\nselected text\n```\nafter")
        #expect(
            (result.text as NSString).substring(with: result.selection)
                == "text"
        )
    }

    @Test("Empty code block starts and ends on complete lines")
    func emptyCodeBlockUsesCompleteLines() {
        let result = MarkdownFormatting.wrapCodeBlock(
            in: "beforeafter",
            selection: NSRange(location: 6, length: 0)
        )

        #expect(result.text == "before\n```\n\n```\nafter")
        #expect(result.selection == NSRange(location: 11, length: 0))
    }

    @Test("Inline code delimiter exceeds content backtick runs")
    func inlineCodeUsesLongerDelimiter() {
        let text = "a`b"
        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: NSRange(location: 0, length: 3)
        )

        #expect(result.text == "``a`b``")
        #expect(result.selection == NSRange(location: 2, length: 3))
    }

    @Test("Inline code pads content with edge backticks")
    func inlineCodePadsEdgeBackticks() {
        let text = "foo`"
        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: NSRange(location: 0, length: 4)
        )

        #expect(result.text == "`` foo` ``")
        #expect(result.selection == NSRange(location: 3, length: 4))

        let unwrapped = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: result.text,
            selection: NSRange(
                location: 0,
                length: (result.text as NSString).length
            )
        )
        #expect(unwrapped.text == text)
    }

    @Test("Code block fence exceeds backticks in selected content")
    func codeBlockFenceExceedsContentRun() {
        let text = "```\ninside\n```\n"
        let result = MarkdownFormatting.wrapCodeBlock(
            in: text,
            selection: NSRange(
                location: 0,
                length: (text as NSString).length
            )
        )

        #expect(result.text.hasPrefix("````\n"))
        #expect(result.text.hasSuffix("````\n"))
    }

    @Test("Italic uses an intraword-safe asterisk delimiter")
    func italicUsesAsteriskDelimiter() {
        let result = MarkdownFormatting.toggleInline(
            .italic,
            in: "foobar",
            selection: NSRange(location: 1, length: 3)
        )

        #expect(result.text == "f*oob*ar")
    }

    @Test("Newline continues common list markers")
    func newlineContinuesLists() {
        let bullet = MarkdownFormatting.insertNewline(
            in: "- item",
            selection: NSRange(location: 6, length: 0)
        )
        let numbered = MarkdownFormatting.insertNewline(
            in: "3. item",
            selection: NSRange(location: 7, length: 0)
        )
        let task = MarkdownFormatting.insertNewline(
            in: "- [x] done",
            selection: NSRange(location: 10, length: 0)
        )

        #expect(bullet.text == "- item\n- ")
        #expect(numbered.text == "3. item\n4. ")
        #expect(task.text == "- [x] done\n- [ ] ")
    }

    @Test("Newline on empty list item removes its marker")
    func newlineEndsEmptyList() {
        let result = MarkdownFormatting.insertNewline(
            in: "- item\n- ",
            selection: NSRange(location: 9, length: 0)
        )

        #expect(result.text == "- item\n")
        #expect(result.selection == NSRange(location: 7, length: 0))
    }

    @Test("Oversized ordered marker does not overflow")
    func oversizedOrderedMarkerDoesNotOverflow() {
        let text = "9223372036854775807. item"
        let result = MarkdownFormatting.insertNewline(
            in: text,
            selection: NSRange(
                location: (text as NSString).length,
                length: 0
            )
        )

        #expect(result.text == text + "\n")
    }

    @Test("Link wraps selected label")
    func linkWrapsSelectedLabel() {
        let result = MarkdownFormatting.insertLink(
            destination: "https://example.com/a_(b)",
            in: "Example",
            selection: NSRange(location: 0, length: 7)
        )

        #expect(
            result.text == "[Example](https://example.com/a_%28b%29)"
        )
        #expect(result.selection == NSRange(location: 1, length: 7))
    }

    @Test("Link escapes Markdown metacharacters in label")
    func linkEscapesLabel() {
        let result = MarkdownFormatting.insertLink(
            destination: "https://example.com",
            in: #"a]b\c"#,
            selection: NSRange(location: 0, length: 5)
        )

        #expect(
            result.text == #"[a\]b\\c](https://example.com)"#
        )
        #expect(MarkdownRenderer.render(result.text).text == #"a]b\c"#)
    }

    @Test("Horizontal rule gets surrounding line breaks")
    func horizontalRuleGetsLineBreaks() {
        let result = MarkdownFormatting.insertHorizontalRule(
            in: "beforeafter",
            selection: NSRange(location: 6, length: 0)
        )

        #expect(result.text == "before\n***\n\nafter")
    }
}
