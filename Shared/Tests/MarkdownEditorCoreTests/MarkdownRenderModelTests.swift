import Foundation
import Testing
@testable import MarkdownEditorCore

@Suite("Markdown render model")
struct MarkdownRenderModelTests {
    @Test("Common block and inline Markdown renders without syntax")
    func commonMarkdownRendersWithoutSyntax() {
        let source = """
            # Title

            - **Bold** and _italic_
            1. [Link](https://example.com)
            - [x] Done
            > Quote
            """

        let model = MarkdownRenderer.render(source)

        #expect(
            model.text == """
                Title

                • Bold and italic
                1. Link
                ☑ Done
                Quote
                """
        )
        #expect(model.spans.contains { $0.style == .heading(1) })
        #expect(model.spans.contains { $0.style == .bold })
        #expect(model.spans.contains { $0.style == .italic })
        #expect(model.spans.contains { $0.style == .bulletedList })
        #expect(model.spans.contains { $0.style == .numberedList })
        #expect(model.spans.contains { $0.style == .taskList(checked: true) })
        #expect(model.spans.contains { $0.style == .quote })
        #expect(
            model.spans.contains {
                $0.style == .link(destination: "https://example.com")
            }
        )
    }

    @Test("Inline style content selection excludes its delimiters")
    func inlineSelectionMapsToContent() {
        let source = "Before **bold** after"
        let model = MarkdownRenderer.render(source)
        let renderedSelection = (model.text as NSString).range(of: "bold")

        let sourceSelection = model.sourceRange(for: renderedSelection)

        #expect(
            (source as NSString).substring(with: sourceSelection) == "bold"
        )
        #expect(
            (source as NSString).substring(
                with: model.sourceRange(
                    for: renderedSelection,
                    includingMarkup: true
                )
            ) == "**bold**"
        )
    }

    @Test("Selecting a heading preserves its block marker")
    func headingSelectionMapsOnlyVisibleContent() {
        let source = "# Title"
        let model = MarkdownRenderer.render(source)
        let renderedSelection = (model.text as NSString).range(of: "Title")

        #expect(
            (source as NSString).substring(
                with: model.sourceRange(for: renderedSelection)
            ) == "Title"
        )
    }

    @Test("Partial inline edit maps only content")
    func partialInlineEditMapsOnlyContent() {
        let source = "Before **bold** after"
        let model = MarkdownRenderer.render(source)
        let renderedSelection = (model.text as NSString).range(of: "ol")

        let sourceSelection = model.sourceRange(for: renderedSelection)

        #expect((source as NSString).substring(with: sourceSelection) == "ol")
    }

    @Test("Deleting final styled character excludes closing delimiter")
    func deletingFinalStyledCharacterExcludesClosingDelimiter() {
        let source = "**bold**"
        let model = MarkdownRenderer.render(source)
        let renderedRange = (model.text as NSString).range(of: "d")

        let sourceRange = model.sourceRange(for: renderedRange)

        #expect((source as NSString).substring(with: sourceRange) == "d")
    }

    @Test("Empty link does not absorb adjacent visual selection")
    func emptyLinkDoesNotAbsorbAdjacentSelection() {
        let source = "[](https://example.com)x"
        let model = MarkdownRenderer.render(source)
        let renderedRange = (model.text as NSString).range(of: "x")

        let sourceRange = model.sourceRange(for: renderedRange)

        #expect((source as NSString).substring(with: sourceRange) == "x")
    }

    @Test("Visual edit updates source without dropping surrounding markup")
    func visualEditPreservesSurroundingMarkup() {
        let source = "Before **bold** after"
        let model = MarkdownRenderer.render(source)
        let renderedSelection = (model.text as NSString).range(of: "ol")
        let sourceSelection = model.sourceRange(for: renderedSelection)
        let editedSource = NSMutableString(string: source)

        editedSource.replaceCharacters(in: sourceSelection, with: "XX")

        #expect(editedSource == "Before **bXXd** after")
        #expect(
            MarkdownRenderer.render(editedSource as String).text
                == "Before bXXd after"
        )
    }

    @Test("Source selection inside markup maps back to rendered content")
    func sourceSelectionMapsToRenderedContent() {
        let source = "**bold**"
        let model = MarkdownRenderer.render(source)

        let renderedSelection = model.renderedRange(
            for: NSRange(location: 2, length: 4)
        )

        #expect(
            (model.text as NSString).substring(with: renderedSelection)
                == "bold"
        )
    }

    @Test("Source caret remains a rendered caret across hidden markup")
    func sourceCaretRemainsZeroLength() {
        let heading = MarkdownRenderer.render("# Title")
        let emptyCode = MarkdownRenderer.render("```\n\n```")

        #expect(
            heading.renderedRange(
                for: NSRange(location: 2, length: 0)
            ) == NSRange(location: 0, length: 0)
        )
        #expect(
            emptyCode.renderedRange(
                for: NSRange(location: 4, length: 0)
            ).length == 0
        )
    }

    @Test("Image renders as one atomic placeholder")
    func imageRendersAsAtomicPlaceholder() {
        let source = "A ![Photo](Post.assets/photo.png) here"
        let model = MarkdownRenderer.render(source)
        let attachmentRange = (model.text as NSString).range(of: "\u{FFFC}")

        #expect(attachmentRange.length == 1)
        #expect(
            model.sourceRange(for: attachmentRange)
                == (source as NSString).range(
                    of: "![Photo](Post.assets/photo.png)"
                )
        )
        #expect(
            model.spans.contains {
                $0.style == .image(
                    altText: "Photo",
                    destination: "Post.assets/photo.png"
                )
            }
        )
    }

    @Test("Balanced parentheses remain inside link destinations")
    func balancedParenthesesRemainInDestination() {
        let source = "[Docs](https://example.com/a_(b))"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "Docs")
        #expect(
            model.spans.contains {
                $0.style == .link(
                    destination: "https://example.com/a_(b)"
                )
            }
        )
    }

    @Test("Nested and escaped brackets remain in link label")
    func bracketsRemainInLinkLabel() {
        let source = #"[a \[bracket\] and [nested]](https://example.com)"#
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "a [bracket] and [nested]")
        #expect(
            model.spans.contains {
                $0.style == .link(destination: "https://example.com")
            }
        )
    }

    @Test("Fenced code hides fences and preserves code")
    func fencedCodeHidesFences() {
        let source = "```swift\nlet value = 1\n```\n"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "let value = 1\n")
        #expect(
            model.spans.contains {
                $0.style == .codeBlock("swift")
                    && $0.includesMarkup
            }
        )
    }

    @Test("Longer fence can close a shorter opening fence")
    func longerFenceClosesCodeBlock() {
        let source = "```\ncode\n````\n"

        #expect(MarkdownRenderer.render(source).text == "code\n")
    }

    @Test("Backticks in fence info do not open a code block")
    func backtickInfoDoesNotOpenFence() {
        let source = "```foo```\n"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "foo\n")
        #expect(!model.spans.contains {
            if case .codeBlock = $0.style {
                return true
            }
            return false
        })
    }

    @Test("Code span closer must be an exact maximal run")
    func codeSpanRequiresExactRun() {
        let source = "`a``"

        #expect(MarkdownRenderer.render(source).text == source)
    }

    @Test("Code span padding preserves edge backticks")
    func codeSpanPaddingPreservesEdgeBacktick() {
        let source = "`` `foo ``"

        #expect(MarkdownRenderer.render(source).text == "`foo")
    }

    @Test("Underline strike code and rule render")
    func additionalFormattingRenders() {
        let source = "<u>under</u> ~~strike~~ `code` ``a`b``\n---"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "under strike code a`b\n—")
        #expect(model.spans.contains { $0.style == .underline })
        #expect(model.spans.contains { $0.style == .strikethrough })
        #expect(model.spans.contains { $0.style == .inlineCode })
        #expect(model.spans.contains { $0.style == .horizontalRule })
    }

    @Test("Nested bold does not close surrounding italic")
    func nestedAsteriskRunsRenderCorrectly() {
        let source = "*foo **bar** baz*"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "foo bar baz")
        #expect(model.spans.contains { $0.style == .bold })
        #expect(model.spans.contains { $0.style == .italic })
    }

    @Test("Unknown Markdown remains visible and editable")
    func unknownMarkdownRemainsVisible() {
        let source = "Text ==highlight==, snake_case_value, and <mark>tag</mark>"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == source)
        #expect(
            model.sourceRange(
                for: NSRange(
                    location: 0,
                    length: (model.text as NSString).length
                )
            ) == NSRange(location: 0, length: (source as NSString).length)
        )
    }

    @Test("Escaped Markdown maps back to its escape marker")
    func escapedMarkdownMapsToFullSource() {
        let source = #"Literal \* character"#
        let model = MarkdownRenderer.render(source)
        let renderedSelection = (model.text as NSString).range(of: "*")

        #expect(model.text == "Literal * character")
        #expect(
            (source as NSString).substring(
                with: model.sourceRange(for: renderedSelection)
            ) == #"\*"#
        )
    }

    @Test("Backslashes before letters remain visible")
    func nonMarkdownEscapeRemainsVisible() {
        let source = #"Path C:\Users\Kirupa"#

        #expect(MarkdownRenderer.render(source).text == source)
    }

    @Test("Unicode intraword underscores are not emphasis")
    func unicodeIntrawordUnderscoresStayLiteral() {
        let source = "café_value_"

        #expect(MarkdownRenderer.render(source).text == source)
    }

    @Test("Escaped emphasis delimiter stays in styled content")
    func escapedDelimiterDoesNotCloseEmphasis() {
        let source = #"*a\**"#
        let model = MarkdownRenderer.render(source)

        #expect(model.text == "a*")
        #expect(model.spans.contains { $0.style == .italic })
    }

    // MARK: - Sized images

    @Test("An HTML image tag renders as an image, not as text")
    func htmlImageTagRendersAsAnImage() {
        let model = MarkdownRenderer.render("A <img src=\"a.png\" alt=\"Photo\" width=\"300\" height=\"200\"> b"
        )

        #expect(model.text == "A \u{FFFC} b")
        let image = model.spans.first { span in
            if case .image = span.style { return true }
            return false
        }
        #expect(image != nil)
        if case .image(let altText, let destination, let width, let height) =
            image?.style
        {
            #expect(altText == "Photo")
            #expect(destination == "a.png")
            #expect(width == 300)
            #expect(height == 200)
        }
        #expect(image?.isAtomic == true)
    }

    @Test("A Markdown image has no size")
    func markdownImageHasNoSize() {
        let model = MarkdownRenderer.render("![Photo](a.png)")

        let image = model.spans.first { span in
            if case .image = span.style { return true }
            return false
        }
        if case .image(_, _, let width, let height) = image?.style {
            #expect(width == nil)
            #expect(height == nil)
        } else {
            Issue.record("expected an image span")
        }
    }

    @Test("Tags that are not images are still literal text")
    func otherTagsStayAsText() {
        let source = "A <div src=\"a.png\"> and <imgx src=\"b.png\"> b"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == source)
    }

    @Test("An unterminated tag does not swallow the rest of the line")
    func unterminatedTagStaysAsText() {
        // Otherwise everything after it would disappear from the document.
        let source = "Check <img src=\"a.png\" in the docs"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == source)
    }

    @Test("An image tag with no source is left as text")
    func tagWithNoSourceStaysAsText() {
        let source = "<img alt=\"nothing\" width=\"10\">"
        let model = MarkdownRenderer.render(source)

        #expect(model.text == source)
    }

    @Test("Sizes that are not positive whole numbers are ignored")
    func nonPixelSizesAreIgnored() {
        let model = MarkdownRenderer.render("<img src=\"a.png\" width=\"50%\" height=\"0\">"
        )

        let image = model.spans.first { span in
            if case .image = span.style { return true }
            return false
        }
        if case .image(_, let destination, let width, let height) =
            image?.style
        {
            #expect(destination == "a.png")
            #expect(width == nil)
            #expect(height == nil)
        } else {
            Issue.record("expected an image span")
        }
    }

    @Test("A sized image maps back to the exact text that produced it")
    func sizedImageReportsItsSourceRange() {
        // The resize panel replaces this range, so an offset that is off by
        // even one corrupts the document.
        let source = "🌱 <img src=\"a.png\" width=\"300\"> tail"
        let model = MarkdownRenderer.render(source)

        let image = model.spans.first { span in
            if case .image = span.style { return true }
            return false
        }
        #expect(
            (source as NSString).substring(with: image!.sourceRange)
                == "<img src=\"a.png\" width=\"300\">"
        )
    }
}
