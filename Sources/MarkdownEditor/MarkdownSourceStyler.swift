import AppKit
import MarkdownEditorCore

@MainActor
enum MarkdownSourceStyler {
    static func apply(_ markdown: String, to textView: NSTextView) {
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            undoManager?.enableUndoRegistration()
        }
        textView.textStorage?.setAttributedString(
            attributedString(for: markdown)
        )
        updateTypingAttributes(in: textView)
    }

    static func updateTypingAttributes(in textView: NSTextView) {
        guard let textStorage = textView.textStorage,
            textStorage.length > 0
        else {
            textView.typingAttributes = baseAttributes()
            return
        }

        let selectionLocation = textView.selectedRange().location
        if selectionLocation >= textStorage.length,
            textView.string.hasSuffix("\n")
        {
            textView.typingAttributes = baseAttributes()
            return
        }
        let location = min(selectionLocation, textStorage.length - 1)
        textView.typingAttributes = textStorage.attributes(
            at: max(0, location),
            effectiveRange: nil
        )
    }

    private static func attributedString(
        for markdown: String
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: markdown,
            attributes: baseAttributes()
        )
        let source = markdown as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        for span in MarkdownRenderer.render(markdown).spans {
            switch span.style {
            case .heading(let level):
                let paragraphRange = NSIntersectionRange(
                    source.paragraphRange(for: span.sourceRange),
                    fullRange
                )
                guard paragraphRange.length > 0 else {
                    continue
                }
                let paragraphStyle = baseParagraphStyle()
                paragraphStyle.paragraphSpacingBefore = level <= 2 ? 14 : 9
                paragraphStyle.paragraphSpacing = 8
                text.addAttributes(
                    [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: MarkdownTypography.headingFontSize(
                                level: level
                            ),
                            weight: .bold
                        ),
                        .paragraphStyle: paragraphStyle
                    ],
                    range: paragraphRange
                )
            case .codeBlock where span.includesMarkup:
                let codeRange = NSIntersectionRange(
                    span.sourceRange,
                    fullRange
                )
                guard codeRange.length > 0 else {
                    continue
                }
                text.addAttribute(
                    .font,
                    value: NSFont.monospacedSystemFont(
                        ofSize: MarkdownTypography.codeFontSize,
                        weight: .regular
                    ),
                    range: codeRange
                )
            default:
                continue
            }
        }

        return text
    }

    private static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(
                ofSize: MarkdownTypography.bodyFontSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: baseParagraphStyle()
        ]
    }

    private static func baseParagraphStyle() -> NSMutableParagraphStyle {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 2
        paragraphStyle.paragraphSpacing = 7
        return paragraphStyle
    }
}
