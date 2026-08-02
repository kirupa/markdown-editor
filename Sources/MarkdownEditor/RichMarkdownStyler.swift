import AppKit
import MarkdownEditorCore

enum RichMarkdownStyler {
    static func attributedString(
        for model: MarkdownRenderModel,
        documentURL: URL?
    ) -> NSAttributedString {
        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.lineSpacing = 2
        baseParagraphStyle.paragraphSpacing = 7

        let attributedText = NSMutableAttributedString(
            string: model.text,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: MarkdownTypography.bodyFontSize
                ),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: baseParagraphStyle
            ]
        )

        for span in model.spans
        where span.style.isBlockStyle
            && (!span.isAtomic || span.style.usesAtomicBlockStyling)
        {
            applyBlockStyle(span, to: attributedText)
        }
        for span in model.spans
        where !span.style.isBlockStyle
            || (span.isAtomic && !span.style.usesAtomicBlockStyling)
        {
            applyInlineStyle(
                span,
                to: attributedText,
                documentURL: documentURL
            )
        }

        return attributedText
    }

    private static func applyBlockStyle(
        _ span: MarkdownRenderSpan,
        to text: NSMutableAttributedString
    ) {
        let range = clamped(span.renderedRange, to: text.length)
        guard range.length > 0 else {
            return
        }

        switch span.style {
        case .heading(let level):
            text.addAttribute(
                .font,
                value: NSFont.systemFont(
                    ofSize: MarkdownTypography.headingFontSize(level: level),
                    weight: .bold
                ),
                range: range
            )
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.paragraphSpacingBefore = level <= 2 ? 14 : 9
            paragraphStyle.paragraphSpacing = 8
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
        case .codeBlock:
            guard span.includesMarkup else {
                return
            }
            text.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: MarkdownTypography.codeFontSize,
                        weight: .regular
                    ),
                    .markdownCodeBlockBackground: true
                ],
                range: range
            )
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = 14
            paragraphStyle.headIndent = 14
            paragraphStyle.tailIndent = -14
            paragraphStyle.lineSpacing = 1
            paragraphStyle.paragraphSpacingBefore = 0
            paragraphStyle.paragraphSpacing = 0
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
            applyCodeBlockSpacing(
                paragraphStyle,
                range: range,
                to: text
            )
        case .quote:
            text.addAttribute(
                .foregroundColor,
                value: NSColor.secondaryLabelColor,
                range: range
            )
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = 20
            paragraphStyle.headIndent = 20
            paragraphStyle.tailIndent = -8
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
        case .bulletedList, .numberedList, .taskList:
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = 5
            paragraphStyle.headIndent = 24
            paragraphStyle.tabStops = [
                NSTextTab(
                    textAlignment: .left,
                    location: 24
                )
            ]
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
        case .horizontalRule:
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.alignment = .center
            paragraphStyle.paragraphSpacingBefore = 8
            paragraphStyle.paragraphSpacing = 8
            text.addAttributes(
                [
                    .foregroundColor: NSColor.separatorColor,
                    .font: NSFont.systemFont(ofSize: 24, weight: .light),
                    .kern: 6,
                    .paragraphStyle: paragraphStyle
                ],
                range: range
            )
        default:
            break
        }
    }

    private static func applyInlineStyle(
        _ span: MarkdownRenderSpan,
        to text: NSMutableAttributedString,
        documentURL: URL?
    ) {
        let range = clamped(span.renderedRange, to: text.length)
        guard range.length > 0 else {
            return
        }

        switch span.style {
        case .bold:
            applyFontTrait(.boldFontMask, to: text, range: range)
        case .italic:
            applyFontTrait(.italicFontMask, to: text, range: range)
        case .underline:
            text.addAttribute(
                .underlineStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .strikethrough:
            text.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: range
            )
        case .inlineCode:
            text.addAttributes(
                [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: MarkdownTypography.codeFontSize,
                        weight: .regular
                    ),
                    .backgroundColor: NSColor.quaternaryLabelColor
                        .withAlphaComponent(0.2)
                ],
                range: range
            )
        case .link(let destination):
            text.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: NSColor.linkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        case .image(let altText, let destination):
            let attachment = imageAttachment(
                altText: altText,
                destination: destination,
                documentURL: documentURL
            )
            text.addAttribute(
                .attachment,
                value: attachment,
                range: range
            )
        case .taskList(let checked):
            text.addAttribute(
                .foregroundColor,
                value: checked ? NSColor.systemGreen : NSColor.controlAccentColor,
                range: range
            )
        case .bulletedList:
            text.addAttribute(
                .foregroundColor,
                value: NSColor.controlAccentColor,
                range: range
            )
        default:
            break
        }
    }

    private static func applyFontTrait(
        _ trait: NSFontTraitMask,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(
                ofSize: MarkdownTypography.bodyFontSize
            )
            text.addAttribute(
                .font,
                value: NSFontManager.shared.convert(
                    font,
                    toHaveTrait: trait
                ),
                range: subrange
            )
        }
    }

    private static func applyCodeBlockSpacing(
        _ paragraphStyle: NSParagraphStyle,
        range: NSRange,
        to text: NSMutableAttributedString
    ) {
        let string = text.string as NSString
        let firstParagraphRange = NSIntersectionRange(
            string.paragraphRange(
                for: NSRange(location: range.location, length: 0)
            ),
            range
        )
        let lastParagraphRange = NSIntersectionRange(
            string.paragraphRange(
                for: NSRange(
                    location: max(range.location, NSMaxRange(range) - 1),
                    length: 0
                )
            ),
            range
        )

        if NSEqualRanges(firstParagraphRange, lastParagraphRange) {
            let singleParagraphStyle = paragraphStyle.mutableCopy()
                as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            singleParagraphStyle.paragraphSpacingBefore = 7
            singleParagraphStyle.paragraphSpacing = 7
            text.addAttribute(
                .paragraphStyle,
                value: singleParagraphStyle,
                range: firstParagraphRange
            )
            return
        }

        let firstParagraphStyle = paragraphStyle.mutableCopy()
            as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        firstParagraphStyle.paragraphSpacingBefore = 7
        text.addAttribute(
            .paragraphStyle,
            value: firstParagraphStyle,
            range: firstParagraphRange
        )

        let lastParagraphStyle = paragraphStyle.mutableCopy()
            as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        lastParagraphStyle.paragraphSpacing = 7
        text.addAttribute(
            .paragraphStyle,
            value: lastParagraphStyle,
            range: lastParagraphRange
        )
    }

    private static func imageAttachment(
        altText: String,
        destination: String,
        documentURL: URL?
    ) -> NSTextAttachment {
        let image = localImage(
            destination: destination,
            documentURL: documentURL
        ) ?? NSImage(
            systemSymbolName: "photo",
            accessibilityDescription: altText
        ) ?? NSImage(size: NSSize(width: 48, height: 48))

        let maxSize = NSSize(width: 560, height: 380)
        let sourceSize = image.size
        let widthScale = sourceSize.width > 0
            ? maxSize.width / sourceSize.width
            : 1
        let heightScale = sourceSize.height > 0
            ? maxSize.height / sourceSize.height
            : 1
        let scale = min(1, widthScale, heightScale)

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: -4,
            width: max(24, sourceSize.width * scale),
            height: max(24, sourceSize.height * scale)
        )
        return attachment
    }

    private static func localImage(
        destination: String,
        documentURL: URL?
    ) -> NSImage? {
        guard let documentURL else {
            return nil
        }
        let unescapedDestination = destination
            .replacingOccurrences(of: "\\)", with: ")")
        let decodedDestination = unescapedDestination.removingPercentEncoding
            ?? unescapedDestination
        guard !decodedDestination.contains("://") else {
            return nil
        }

        let documentDirectory = documentURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let imageURL = URL(
            fileURLWithPath: decodedDestination,
            relativeTo: documentDirectory
        )
        .resolvingSymlinksInPath()
        .standardizedFileURL
        let directoryPrefix = documentDirectory.path.hasSuffix("/")
            ? documentDirectory.path
            : documentDirectory.path + "/"
        guard imageURL.path.hasPrefix(directoryPrefix) else {
            return nil
        }
        return NSImage(contentsOf: imageURL)
    }

    private static func paragraphStyle(
        in text: NSAttributedString,
        at location: Int
    ) -> NSMutableParagraphStyle {
        guard text.length > 0 else {
            return NSMutableParagraphStyle()
        }
        let safeLocation = min(max(0, location), text.length - 1)
        return (
            text.attribute(
                .paragraphStyle,
                at: safeLocation,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

private extension MarkdownRenderStyle {
    var isBlockStyle: Bool {
        switch self {
        case .heading, .codeBlock, .quote, .horizontalRule:
            true
        case .bulletedList, .numberedList, .taskList:
            true
        default:
            false
        }
    }

    var usesAtomicBlockStyling: Bool {
        if case .horizontalRule = self {
            return true
        }
        return false
    }
}
