import Foundation
import Testing

@testable import MarkdownEditorCore

/// Formatting where Markdown is inert.
///
/// The bug these pin down: the caret was inside a fenced code block, bold was
/// applied, and `**bold text**` went into the document as eleven characters of
/// the writer's code. Nothing in the emphasis path asked what block the
/// selection was in, so nothing could refuse — and the reading view was right
/// to show the markers, because inside a fence that is what they are.
///
/// The block quote half of the same report is here too, as the opposite
/// assertion: a quote is prose, bold in a quote is ordinary Markdown, and
/// these tests fail if a future "fix" starts refusing there.
@Suite("Formatting inside code and quotes")
struct MarkdownCodeContextTests {

    // MARK: - Fenced code blocks

    @Test("The caret inside a fence reports the block, fences and all")
    func caretInsideFenceReportsBlock() {
        let text = "para\n\n```swift\nlet x = 1\n```\n\nafter\n"
        let source = text as NSString
        let block = NSRange(location: 6, length: 23)

        for caret in block.location..<NSMaxRange(block) {
            #expect(
                MarkdownCodeContext.containing(
                    NSRange(location: caret, length: 0),
                    in: text
                ) == .codeBlock(block),
                "caret \(caret) should be inside the block"
            )
        }
        // Just before the fence, and on the blank line after it, is prose.
        #expect(
            MarkdownCodeContext.containing(
                NSRange(location: block.location - 1, length: 0),
                in: text
            ) == .prose
        )
        #expect(
            MarkdownCodeContext.containing(
                NSRange(location: NSMaxRange(block), length: 0),
                in: text
            ) == .prose
        )
        #expect(source.substring(with: block) == "```swift\nlet x = 1\n```\n")
    }

    @Test("Every inline style refuses inside a fenced code block")
    func inlineStylesRefuseInsideFence() {
        // The reported document, before the markers went in.
        let text = "# \n```\nsdf\n\nnsd\n```\n"
        let caret = NSRange(location: 11, length: 0)

        for style in MarkdownInlineStyle.allCases {
            #expect(!MarkdownFormatting.isAvailable(style, in: text, selection: caret))

            let result = MarkdownFormatting.toggleInline(
                style,
                in: text,
                selection: caret
            )
            #expect(result.text == text, "\(style) wrote into a code block")
            #expect(result.selection == caret)
        }
    }

    @Test("A selected word inside a fence is not bolded")
    func selectionInsideFenceRefuses() {
        let text = "```\nlet total = 1\n```\n"
        let selection = (text as NSString).range(of: "total")

        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: text,
            selection: selection
        )

        #expect(result.text == text)
        #expect(result.selection == selection)
    }

    @Test("A fence line itself refuses, because writing there breaks the fence")
    func fenceLineRefuses() {
        let text = "```swift\nlet x = 1\n```\n"
        for caret in [0, 4, 19, 21] {
            let selection = NSRange(location: caret, length: 0)
            #expect(
                MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text
                    == text,
                "caret \(caret) wrote into a fence line"
            )
        }
    }

    @Test("An unterminated fence is still a code block to the end of the file")
    func unterminatedFenceRefuses() {
        let text = "intro\n\n```\nlet x = 1\n"
        let caret = NSRange(location: 15, length: 0)

        #expect(MarkdownCodeContext.containing(caret, in: text).isCode)
        #expect(
            MarkdownFormatting.toggleInline(.italic, in: text, selection: caret).text == text
        )
    }

    @Test("A link is refused inside a fence as well")
    func linkRefusedInsideFence() {
        let text = "```\nlet x = 1\n```\n"
        let selection = (text as NSString).range(of: "let x")

        #expect(!MarkdownFormatting.isLinkAvailable(in: text, selection: selection))
        #expect(
            MarkdownFormatting.insertLink(
                destination: "https://example.com",
                in: text,
                selection: selection
            ).text == text
        )
    }

    @Test("A quote written inside a fence is code, not a quote")
    func quoteInsideFenceIsCode() {
        let text = "```\n> quoted inside the fence\n```\n"
        let selection = (text as NSString).range(of: "quoted")

        #expect(MarkdownCodeContext.containing(selection, in: text).isCode)
        #expect(
            MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text == text
        )
        // And the renderer agrees: the `>` is shown, because it is code.
        #expect(MarkdownRenderer.render(text).text.contains("> quoted inside the fence"))
    }

    @Test("A fence written inside a quote is a quote, not a fence")
    func fenceInsideQuoteIsProse() {
        // `> ``` ` is not a fence: a fence has to start its own line. So this
        // is a quote and formatting it is allowed.
        let text = "> ```\n> still quoted\n"
        let selection = (text as NSString).range(of: "still")

        #expect(MarkdownCodeContext.containing(selection, in: text) == .prose)
        #expect(
            MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text
                == "> ```\n> **still** quoted\n"
        )
    }

    // MARK: - Inline code spans

    @Test("Emphasis refuses between a code span's backticks")
    func emphasisRefusesInsideCodeSpan() {
        let text = "Call `reload(now:)` to refresh.\n"
        let selection = (text as NSString).range(of: "reload")

        #expect(MarkdownCodeContext.containing(selection, in: text)
            == .inlineCodeSpan(NSRange(location: 5, length: 14)))
        for style in [MarkdownInlineStyle.bold, .italic, .underline, .strikethrough] {
            #expect(!MarkdownFormatting.isAvailable(style, in: text, selection: selection))
            #expect(
                MarkdownFormatting.toggleInline(style, in: text, selection: selection).text
                    == text
            )
        }
        #expect(!MarkdownFormatting.isLinkAvailable(in: text, selection: selection))
    }

    @Test("A selection holding a whole code span may still be emphasised")
    func selectionAroundCodeSpanIsProse() {
        let text = "Call `reload()` now.\n"
        let selection = (text as NSString).range(of: "Call `reload()` now")

        #expect(MarkdownCodeContext.containing(selection, in: text) == .prose)
        #expect(
            MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text
                == "**Call `reload()` now**.\n"
        )
    }

    @Test("A caret at either end of a code span is in the prose beside it")
    func caretAtCodeSpanEdgesIsProse() {
        let text = "a `code` b\n"
        for caret in [2, 8] {
            #expect(
                MarkdownCodeContext.containing(
                    NSRange(location: caret, length: 0),
                    in: text
                ) == .prose,
                "caret \(caret) should be outside the span"
            )
        }
        for caret in 3...7 {
            #expect(
                MarkdownCodeContext.containing(
                    NSRange(location: caret, length: 0),
                    in: text
                ).isCode,
                "caret \(caret) should be inside the span"
            )
        }
    }

    @Test("Inline code stays available inside a span, and takes the span off")
    func inlineCodeTogglesOffFromACaret() {
        let text = "a `code` b\n"
        let caret = NSRange(location: 5, length: 0)

        #expect(MarkdownFormatting.isAvailable(.inlineCode, in: text, selection: caret))

        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: caret
        )

        #expect(result.text == "a code b\n")
        // The caret keeps its place in the word rather than jumping to an end.
        #expect(result.selection == NSRange(location: 4, length: 0))
    }

    @Test("Toggling code off from a caret undoes a padded, doubled delimiter")
    func inlineCodeTogglesOffAPaddedSpan() {
        // `` foo` `` is what wrapping "foo`" produces: a doubled delimiter so
        // the content's own backtick cannot close it, and a space either side
        // so the content's edge backtick is not read as part of the fence.
        // Taking it off has to undo both.
        let text = "a `` foo` `` b\n"
        let caret = NSRange(location: 6, length: 0)

        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: caret
        )

        #expect(result.text == "a foo` b\n")
        #expect(result.selection == NSRange(location: 3, length: 0))
    }

    @Test("A selection crossing a backtick run takes the span off rather than nesting one")
    func inlineCodeStraddlingTheDelimiter() {
        let text = "a `code` b\n"
        // "`cod" — the opening backtick and part of the code.
        let selection = NSRange(location: 2, length: 4)

        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: selection
        )

        #expect(result.text == "a code b\n")
        #expect(MarkdownRenderer.render(result.text).text == "a code b\n")
    }

    @Test("Selecting a code span's contents still toggles it off as it always did")
    func inlineCodeFromContentSelectionIsUnchanged() {
        let text = "Use `value` here"
        let selection = (text as NSString).range(of: "value")

        let result = MarkdownFormatting.toggleInline(
            .inlineCode,
            in: text,
            selection: selection
        )

        #expect(result.text == "Use value here")
        #expect(result.selection == NSRange(location: 4, length: 5))
    }

    // MARK: - Block quotes

    @Test("Bold inside a block quote is written, and its markers are hidden")
    func boldInsideQuoteWorks() {
        let text = "> quoted line\n"
        let selection = (text as NSString).range(of: "quoted")

        #expect(MarkdownCodeContext.containing(selection, in: text) == .prose)
        #expect(MarkdownFormatting.isAvailable(.bold, in: text, selection: selection))

        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: text,
            selection: selection
        )

        #expect(result.text == "> **quoted** line\n")

        // The point of the report: the syntax must not come back on screen.
        let model = MarkdownRenderer.render(result.text)
        #expect(model.text == "quoted line\n")
        #expect(
            model.spans.contains {
                $0.style == .bold && $0.renderedRange == NSRange(location: 0, length: 6)
            }
        )
        #expect(model.spans.contains { $0.style == .quote })
    }

    @Test("Every inline style and a link work in a quote, markers hidden")
    func everyStyleWorksInAQuote() {
        for style in MarkdownInlineStyle.allCases {
            let text = "> quoted line\n"
            let selection = (text as NSString).range(of: "quoted")

            #expect(MarkdownFormatting.isAvailable(style, in: text, selection: selection))

            let result = MarkdownFormatting.toggleInline(
                style,
                in: text,
                selection: selection
            )
            #expect(result.text != text, "\(style) did nothing in a quote")
            #expect(
                MarkdownRenderer.render(result.text).text == "quoted line\n",
                "\(style) left its markers on screen in a quote"
            )
        }

        let text = "> quoted line\n"
        let selection = (text as NSString).range(of: "quoted")
        #expect(MarkdownFormatting.isLinkAvailable(in: text, selection: selection))
    }

    @Test("A nested quote is prose too")
    func nestedQuoteIsProse() {
        let text = "> outer\n>> nested quote\n"
        let selection = (text as NSString).range(of: "nested")

        #expect(MarkdownCodeContext.containing(selection, in: text) == .prose)
        #expect(
            MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text
                == "> outer\n>> **nested** quote\n"
        )
    }

    @Test("A code span inside a quote is still code")
    func codeSpanInsideQuoteIsCode() {
        let text = "> call `reload()` first\n"
        let selection = (text as NSString).range(of: "reload")

        #expect(MarkdownCodeContext.containing(selection, in: text).isCode)
        #expect(
            MarkdownFormatting.toggleInline(.bold, in: text, selection: selection).text == text
        )
    }

    // MARK: - Indented code is not code here

    @Test("A four-space indented line is a paragraph, and formats like one")
    func indentedCodeIsAParagraph() {
        // This renderer does not implement indented code blocks: the line is
        // drawn as ordinary prose, emphasis on it is drawn as emphasis, and so
        // refusing to format it would stop a command that visibly works. If
        // indented code is ever added to `MarkdownRenderModel`, this test
        // should flip rather than be deleted.
        let text = "para\n\n    let x = 1\n"
        let selection = (text as NSString).range(of: "let x")

        #expect(MarkdownRenderer.render(text).spans.isEmpty)
        #expect(MarkdownCodeContext.containing(selection, in: text) == .prose)

        let result = MarkdownFormatting.toggleInline(
            .bold,
            in: text,
            selection: selection
        )

        #expect(result.text == "para\n\n    **let x** = 1\n")
        #expect(MarkdownRenderer.render(result.text).text == "para\n\n    let x = 1\n")
    }
}
