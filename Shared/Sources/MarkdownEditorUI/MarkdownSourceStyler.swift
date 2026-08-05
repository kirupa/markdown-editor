#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation
import MarkdownEditorCore

/// The small surface of a plain-text view the source styler needs.
///
/// `NSTextView` and `UITextView` agree on almost everything here but disagree
/// on the spelling: `string` versus `text`, a method versus a property for the
/// selection, and an optional versus a non-optional text storage. Naming the
/// four things that are actually used keeps the styling rules — which are
/// identical on both platforms — in one place.
@MainActor
public protocol MarkdownSourceTextView: AnyObject {
    var sourceTextStorage: NSTextStorage? { get }
    var sourceText: String { get }
    var sourceSelectionLocation: Int { get }
    var sourceTypingAttributes: [NSAttributedString.Key: Any] { get set }
    var sourceUndoManager: UndoManager? { get }
}

@MainActor
public enum MarkdownSourceStyler {
    public static func apply(
        _ markdown: String,
        to textView: some MarkdownSourceTextView,
        colorTheme: EditorColorTheme
    ) {
        let undoManager = textView.sourceUndoManager
        undoManager?.disableUndoRegistration()
        defer {
            undoManager?.enableUndoRegistration()
        }
        textView.sourceTextStorage?.setAttributedString(
            attributedString(for: markdown, colorTheme: colorTheme)
        )
        updateTypingAttributes(in: textView, colorTheme: colorTheme)
    }

    public static func updateTypingAttributes(
        in textView: some MarkdownSourceTextView,
        colorTheme: EditorColorTheme
    ) {
        guard let textStorage = textView.sourceTextStorage,
            textStorage.length > 0
        else {
            textView.sourceTypingAttributes = baseAttributes(
                colorTheme: colorTheme
            )
            return
        }

        let selectionLocation = textView.sourceSelectionLocation
        if selectionLocation >= textStorage.length,
            textView.sourceText.hasSuffix("\n")
        {
            textView.sourceTypingAttributes = baseAttributes(
                colorTheme: colorTheme
            )
            return
        }
        let location = min(selectionLocation, textStorage.length - 1)
        textView.sourceTypingAttributes = textStorage.attributes(
            at: max(0, location),
            effectiveRange: nil
        )
    }

    public static func attributedString(
        for markdown: String,
        colorTheme: EditorColorTheme
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: markdown,
            attributes: baseAttributes(colorTheme: colorTheme)
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
                        .font: PlatformFont.monospacedSystemFont(
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
                    value: PlatformFont.monospacedSystemFont(
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

    public static func baseAttributes(
        colorTheme: EditorColorTheme
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: PlatformFont.monospacedSystemFont(
                ofSize: MarkdownTypography.bodyFontSize,
                weight: .regular
            ),
            .foregroundColor: colorTheme.primaryTextColor,
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
