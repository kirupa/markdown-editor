#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation
import MarkdownEditorCore

public enum RichMarkdownStyler {
    public static func attributedString(
        for model: MarkdownRenderModel,
        documentURL: URL?,
        colorTheme: EditorColorTheme,
        page: MarkdownPageMetrics? = nil
    ) -> NSAttributedString {
        // The page is wider than the column prose is set in, and every
        // paragraph is indented by the difference so it wraps at the column.
        // A picture is the one thing allowed to give that indent up — see
        // `applyImageParagraphIndent`.
        //
        // Indenting rather than narrowing the container is what makes the
        // margin reachable at all: TextKit compresses an attachment to the
        // width of the line it is on, so a picture can only be wider than the
        // column if its own line is.
        let bleed = page?.bleed ?? 0

        let attributedText = NSMutableAttributedString(
            string: model.text,
            attributes: baseAttributes(colorTheme: colorTheme, bleed: bleed)
        )

        for span in model.spans
        where span.style.isBlockStyle
            && (!span.isAtomic || span.style.usesAtomicBlockStyling)
        {
            applyBlockStyle(
                span,
                to: attributedText,
                colorTheme: colorTheme,
                bleed: bleed
            )
        }
        for span in model.spans
        where !span.style.isBlockStyle
            || (span.isAtomic && !span.style.usesAtomicBlockStyling)
        {
            applyInlineStyle(
                span,
                to: attributedText,
                documentURL: documentURL,
                colorTheme: colorTheme,
                page: page
            )
        }

        return attributedText
    }

    /// What every paragraph starts as, before any block or inline style.
    static func baseAttributes(
        colorTheme: EditorColorTheme,
        bleed: CGFloat
    ) -> [NSAttributedString.Key: Any] {
        let baseParagraphStyle = NSMutableParagraphStyle()
        baseParagraphStyle.lineSpacing = 2
        baseParagraphStyle.paragraphSpacing = 7
        baseParagraphStyle.firstLineHeadIndent = bleed
        baseParagraphStyle.headIndent = bleed
        baseParagraphStyle.tailIndent = -bleed
        return [
            .font: PlatformFont.systemFont(
                ofSize: MarkdownTypography.bodyFontSize
            ),
            .foregroundColor: colorTheme.primaryTextColor,
            .paragraphStyle: baseParagraphStyle
        ]
    }

    /// What the caret at `location` should type with, when the line it sits on
    /// has no characters of its own to say.
    ///
    /// The last line of a document is the one place an attribute cannot reach:
    /// it has no newline, so there is nothing to carry a paragraph style, and
    /// TextKit falls back to the character *before* the caret — which belongs
    /// to the line above and, for a quote, is not even styled as one, because
    /// a quote's span stops short of its own newline.
    ///
    /// The effect was that pressing Enter at the end of a quote wrote `> ` into
    /// the source and drew the new line flush against the margin, so the quote
    /// looked finished while the document said it was not.
    ///
    /// Returns nil wherever the line can speak for itself, which is everywhere
    /// else; the caller then leaves the text view's own typing attributes
    /// alone rather than freezing them at whatever was last computed.
    public static func typingAttributes(
        for model: MarkdownRenderModel,
        at location: Int,
        colorTheme: EditorColorTheme,
        page: MarkdownPageMetrics? = nil
    ) -> [NSAttributedString.Key: Any]? {
        guard location >= (model.text as NSString).length else {
            return nil
        }
        guard let span = model.spans.first(where: {
            $0.style.isBlockStyle
                && $0.renderedRange.length == 0
                && $0.renderedRange.location == location
        }) else {
            return nil
        }

        // Styled by running the real thing over a scratch paragraph rather
        // than by rebuilding the indents here, so an empty line cannot drift
        // from the lines that have text on them.
        let bleed = page?.bleed ?? 0
        let scratch = NSMutableAttributedString(
            string: "\n",
            attributes: baseAttributes(colorTheme: colorTheme, bleed: bleed)
        )
        applyBlockStyle(
            MarkdownRenderSpan(
                style: span.style,
                renderedRange: NSRange(location: 0, length: 1),
                sourceRange: span.sourceRange,
                includesMarkup: span.includesMarkup,
                isAtomic: span.isAtomic
            ),
            to: scratch,
            colorTheme: colorTheme,
            bleed: bleed
        )
        return scratch.attributes(at: 0, effectiveRange: nil)
    }

    private static func applyBlockStyle(
        _ span: MarkdownRenderSpan,
        to text: NSMutableAttributedString,
        colorTheme: EditorColorTheme,
        bleed: CGFloat
    ) {
        let range = styledRange(for: span, in: text)
        guard range.length > 0 else {
            return
        }

        switch span.style {
        case .heading(let level):
            text.addAttribute(
                .font,
                value: PlatformFont.systemFont(
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
                    .font: PlatformFont.monospacedSystemFont(
                        ofSize: MarkdownTypography.codeFontSize,
                        weight: .regular
                    ),
                    .markdownCodeBlockBackground:
                        colorTheme.codeBlockBackgroundColor
                ],
                range: range
            )
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = bleed + 14
            paragraphStyle.headIndent = bleed + 14
            paragraphStyle.tailIndent = -(bleed + 14)
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
                value: colorTheme.secondaryTextColor,
                range: range
            )
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = bleed + 20
            paragraphStyle.headIndent = bleed + 20
            paragraphStyle.tailIndent = -(bleed + 8)
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: range
            )
        case .bulletedList, .numberedList, .taskList:
            let paragraphStyle = paragraphStyle(in: text, at: range.location)
            paragraphStyle.firstLineHeadIndent = bleed + 5
            paragraphStyle.headIndent = bleed + 24
            paragraphStyle.tabStops = [
                NSTextTab(
                    textAlignment: .left,
                    location: bleed + 24
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
                    .foregroundColor: colorTheme.separatorColor,
                    .font: PlatformFont.systemFont(ofSize: 24, weight: .light),
                    .kern: 6,
                    .paragraphStyle: paragraphStyle
                ],
                range: range
            )
        default:
            break
        }
    }

    /// The characters a block span should be drawn over.
    ///
    /// Normally the span's own range. The exception is an **empty line inside
    /// a block** — the one a quote or a list makes the moment Enter is pressed
    /// and before anything has been typed into it. The renderer reports that
    /// line as a zero-length span, because there genuinely is no text on it,
    /// and a zero-length range carries no attributes: `addAttribute` over it
    /// does nothing at all. So the new line was drawn flush against the margin
    /// and the quote looked as though it had ended, while the source said
    /// `> ` and the next character typed appeared indented after all.
    ///
    /// A paragraph style belongs to the paragraph, not to the letters in it,
    /// so an empty paragraph still deserves one. The line's own newline is
    /// what carries it: in TextKit a newline terminates the paragraph it ends,
    /// so the character *at* the span is this line's, while the one before it
    /// belongs to the line above. Extending forward is therefore safe and
    /// extending backwards would indent the wrong paragraph — which is exactly
    /// what a quote typed under a plain sentence would have done.
    ///
    /// A line with no newline after it has no character at all, which no
    /// attribute can reach. That is the last line of the document, and it is
    /// `typingAttributes(for:at:...)` that keeps it indented.
    private static func styledRange(
        for span: MarkdownRenderSpan,
        in text: NSMutableAttributedString
    ) -> NSRange {
        let range = clamped(span.renderedRange, to: text.length)
        guard range.length == 0, range.location < text.length else {
            return range
        }
        let next = NSRange(location: range.location, length: 1)
        guard (text.string as NSString).substring(with: next) == "\n" else {
            return range
        }
        return next
    }

    private static func applyInlineStyle(
        _ span: MarkdownRenderSpan,
        to text: NSMutableAttributedString,
        documentURL: URL?,
        colorTheme: EditorColorTheme,
        page: MarkdownPageMetrics?
    ) {
        let range = clamped(span.renderedRange, to: text.length)
        guard range.length > 0 else {
            return
        }

        switch span.style {
        case .bold:
            applyFontTrait(.bold, to: text, range: range)
        case .italic:
            applyFontTrait(.italic, to: text, range: range)
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
                    .font: PlatformFont.monospacedSystemFont(
                        ofSize: MarkdownTypography.codeFontSize,
                        weight: .regular
                    ),
                    .backgroundColor:
                        colorTheme.inlineCodeBackgroundColor
                ],
                range: range
            )
        case .link(let destination):
            text.addAttributes(
                [
                    .link: destination,
                    .foregroundColor: PlatformColor.markdownLinkColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue
                ],
                range: range
            )
        case .image(let altText, let destination, let width, let height):
            let attachment = imageAttachment(
                altText: altText,
                destination: destination,
                width: width,
                height: height,
                documentURL: documentURL,
                maximumWidth: page?.maximumImageWidth
            )
            text.addAttribute(
                .attachment,
                value: attachment,
                range: range
            )
            applyImageParagraphIndent(
                imageWidth: attachment.bounds.width,
                imageRange: range,
                to: text,
                page: page
            )
        case .taskList(let checked):
            text.addAttribute(
                .foregroundColor,
                value: checked
                    ? PlatformColor.systemGreen
                    : PlatformColor.markdownAccentColor,
                range: range
            )
        case .bulletedList:
            text.addAttribute(
                .foregroundColor,
                value: PlatformColor.markdownAccentColor,
                range: range
            )
        default:
            break
        }
    }

    private static func applyFontTrait(
        _ trait: MarkdownFontTrait,
        to text: NSMutableAttributedString,
        range: NSRange
    ) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? PlatformFont ?? PlatformFont.systemFont(
                ofSize: MarkdownTypography.bodyFontSize
            )
            text.addAttribute(
                .font,
                value: font.markdownFont(withTrait: trait),
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

    /// Let a picture spread into the page's margins as it outgrows the column.
    ///
    /// Only when the picture is the whole paragraph. A picture sitting in a
    /// sentence is part of that sentence's line, and pulling the line's indent
    /// out from under the words around it would drag them into the margin too.
    private static func applyImageParagraphIndent(
        imageWidth: CGFloat,
        imageRange: NSRange,
        to text: NSMutableAttributedString,
        page: MarkdownPageMetrics?
    ) {
        guard let page, page.bleed > 0 else { return }
        let string = text.string as NSString
        let paragraph = string.paragraphRange(for: imageRange)
        guard paragraph.length > 0, isAlone(
            imageRange: imageRange,
            inParagraph: paragraph,
            of: string
        ) else {
            return
        }
        let indent = page.imageParagraphIndent(imageWidth: imageWidth)
        let style = paragraphStyle(in: text, at: paragraph.location)
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.tailIndent = -indent
        text.addAttribute(.paragraphStyle, value: style, range: paragraph)
    }

    /// Whether `imageRange` is all its paragraph holds, give or take the
    /// newline that ends it.
    private static func isAlone(
        imageRange: NSRange,
        inParagraph paragraph: NSRange,
        of string: NSString
    ) -> Bool {
        let before = NSRange(
            location: paragraph.location,
            length: max(0, imageRange.location - paragraph.location)
        )
        let afterStart = imageRange.location + imageRange.length
        let paragraphEnd = paragraph.location + paragraph.length
        let after = NSRange(
            location: min(afterStart, paragraphEnd),
            length: max(0, paragraphEnd - afterStart)
        )
        let neighbours = string.substring(with: before)
            + string.substring(with: after)
        return neighbours.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private static func imageAttachment(
        altText: String,
        destination: String,
        width: Int?,
        height: Int?,
        documentURL: URL?,
        maximumWidth: CGFloat?
    ) -> NSTextAttachment {
        let image = localImage(
            destination: destination,
            documentURL: documentURL
        ) ?? RemoteImageStore.shared.image(
            for: destination
        ) ?? PlatformImage.markdownSymbol(
            named: "photo",
            accessibilityDescription: altText
        ) ?? PlatformImage.markdownBlank(
            size: CGSize(width: 48, height: 48)
        )

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            origin: CGPoint(x: 0, y: -4),
            size: displaySize(
                of: image.size,
                width: width,
                height: height,
                maximumWidth: maximumWidth
            )
        )
        return attachment
    }

    /// How large to draw an image.
    ///
    /// A size written into the document is the author's instruction and wins,
    /// so the default cap must not quietly override it. When only one dimension
    /// is given the other is derived from the image's own shape, which is more
    /// accurate than anything the document could carry.
    static func displaySize(
        of sourceSize: CGSize,
        width: Int?,
        height: Int?,
        maximumWidth: CGFloat? = nil
    ) -> CGSize {
        let fitted = fit(
            unconstrainedDisplaySize(of: sourceSize, width: width, height: height),
            within: maximumWidth
        )
        return fitted
    }

    /// Hold a picture to the page **without changing its shape**.
    ///
    /// TextKit's answer to a picture wider than the line it is on is to squash
    /// it horizontally and carry on using the height it was asked for, so the
    /// picture comes out the wrong shape and nothing says so. Measured on a
    /// phone: a 1600x300 picture defaulting to 560 wide in a 368pt column drew
    /// 384x107, where its own shape at that width is 384x72.
    ///
    /// Scaling both sides is the only answer that keeps the picture itself
    /// honest. It changes what is *drawn*, never what is written: the document
    /// keeps the size it asked for, so opening it somewhere wider shows it at
    /// that size again.
    private static func fit(
        _ size: CGSize,
        within maximumWidth: CGFloat?
    ) -> CGSize {
        guard let maximumWidth, maximumWidth > 0, size.width > maximumWidth else {
            return size
        }
        let scale = maximumWidth / size.width
        return CGSize(
            width: maximumWidth,
            height: max(1, size.height * scale)
        )
    }

    private static func unconstrainedDisplaySize(
        of sourceSize: CGSize,
        width: Int?,
        height: Int?
    ) -> CGSize {
        let hasSourceSize = sourceSize.width > 0 && sourceSize.height > 0
        let aspect = hasSourceSize
            ? sourceSize.height / sourceSize.width
            : 1

        if let width, width > 0 {
            let requestedWidth = CGFloat(width)
            let requestedHeight = height.map(CGFloat.init)
                ?? (requestedWidth * aspect)
            return CGSize(
                width: requestedWidth,
                height: max(1, requestedHeight)
            )
        }
        if let height, height > 0 {
            let requestedHeight = CGFloat(height)
            let derivedWidth = aspect > 0
                ? requestedHeight / aspect
                : requestedHeight
            return CGSize(width: max(1, derivedWidth), height: requestedHeight)
        }

        let maxSize = CGSize(width: 560, height: 380)
        let widthScale = sourceSize.width > 0
            ? maxSize.width / sourceSize.width
            : 1
        let heightScale = sourceSize.height > 0
            ? maxSize.height / sourceSize.height
            : 1
        let scale = min(1, widthScale, heightScale)
        return CGSize(
            width: max(24, sourceSize.width * scale),
            height: max(24, sourceSize.height * scale)
        )
    }

    private static func localImage(
        destination: String,
        documentURL: URL?
    ) -> PlatformImage? {
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
        // Deliberately no "must be under the document's folder" rule here.
        //
        // That rule is real, but it belongs to *importing* — I-18, where this
        // app writes a file and must not write outside the document's own
        // folder. Reading is not the same act. A document that says
        // `../images/photo.png` is describing the reader's own file, in the
        // layout every static site generator and most note-takers produce, and
        // the app can already open anything its reader can. Enforcing the write
        // rule on the read path did not protect anything: it just replaced the
        // picture with a generic placeholder icon and said nothing about why.
        return LocalImageStore.shared.image(at: imageURL)
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
