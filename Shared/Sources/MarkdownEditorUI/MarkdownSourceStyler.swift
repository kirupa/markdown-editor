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
        // Styling is not an edit, so it must not land on the undo stack — but
        // `enableUndoRegistration` throws if the manager is not currently
        // disabled, and UIKit resets that count out from under us when the
        // text storage is replaced (`removeAllActions` re-enables). Balancing
        // the calls blindly therefore crashes the source pane on iOS the
        // first time it is shown. Only undo what we actually did.
        let didDisable = undoManager?.isUndoRegistrationEnabled ?? false
        if didDisable {
            undoManager?.disableUndoRegistration()
        }
        defer {
            if didDisable, undoManager?.isUndoRegistrationEnabled == false {
                undoManager?.enableUndoRegistration()
            }
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
        applySpans(to: text, of: markdown, at: 0)
        return text
    }

    /// Re-applies the styling over the one block an edit landed in.
    ///
    /// The source pane used to build an attributed string for the whole
    /// document and hand it to the text storage on every keystroke, which
    /// threw away the layout of every line in the file to restyle one of them.
    /// Here the characters are not touched at all — only the attributes over
    /// the affected block — so nothing outside it is disturbed and the caret
    /// and undo stack are left alone.
    ///
    /// Sound for the same reason the rendered pane's version is: both rules
    /// this styler has reach no further than the span they came from, and a
    /// block never shares a line with another. `MarkdownSourceStylerTests`
    /// checks it against a full restyle.
    public static func restyle(
        blockContaining changedRange: NSRange,
        in textView: some MarkdownSourceTextView,
        colorTheme: EditorColorTheme
    ) {
        guard let textStorage = textView.sourceTextStorage,
            textStorage.length > 0
        else {
            updateTypingAttributes(in: textView, colorTheme: colorTheme)
            return
        }
        let source = textStorage.string as NSString
        let start = min(max(0, changedRange.location), source.length)
        let end = min(max(start, NSMaxRange(changedRange)), source.length)
        let first = MarkdownBlockScanner.blockRange(
            containing: start,
            in: source
        )
        let last = end > start
            ? MarkdownBlockScanner.blockRange(
                containing: max(start, end - 1),
                in: source
            )
            : first
        let block = NSIntersectionRange(
            NSUnionRange(first, last),
            NSRange(location: 0, length: source.length)
        )
        guard block.length > 0 else {
            updateTypingAttributes(in: textView, colorTheme: colorTheme)
            return
        }

        textStorage.beginEditing()
        textStorage.setAttributes(
            baseAttributes(colorTheme: colorTheme),
            range: block
        )
        applySpans(
            to: textStorage,
            of: source.substring(with: block),
            at: block.location
        )
        textStorage.endEditing()
        updateTypingAttributes(in: textView, colorTheme: colorTheme)
    }

    /// The two rules this styler has, applied over `text` starting at `offset`.
    private static func applySpans(
        to text: NSMutableAttributedString,
        of markdown: String,
        at offset: Int
    ) {
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
                    range: NSRange(
                        location: paragraphRange.location + offset,
                        length: paragraphRange.length
                    )
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
                    range: NSRange(
                        location: codeRange.location + offset,
                        length: codeRange.length
                    )
                )
            default:
                continue
            }
        }
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
