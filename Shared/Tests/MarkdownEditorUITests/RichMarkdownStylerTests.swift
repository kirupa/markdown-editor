#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

import CoreGraphics
import Foundation
import MarkdownEditorContract
import MarkdownEditorCore
import Testing
@testable import MarkdownEditorUI

/// What the rendered pane is built from.
///
/// The attributed string this produces is assigned straight into the text
/// view's storage, while the span table that produced it stays behind to map
/// edits back into the Markdown source. The two only agree if the string is
/// exactly as long as the model text — one character of drift and every edit
/// after that point is written to the wrong place in the file.
///
/// That is the property worth holding, and none of it was covered before.
@Suite("Rich Markdown styler")
struct RichMarkdownStylerTests {
    /// A representative spread rather than all sixteen, since the styler
    /// treats a palette as opaque; the palettes themselves are checked in
    /// `EditorColorThemeTests`.
    private static var themes: [EditorColorTheme] {
        [
            EditorColorTheme(color: .blue, mode: .light),
            EditorColorTheme(color: .blue, mode: .dark),
            EditorColorTheme(color: .green, mode: .light),
            EditorColorTheme(color: .purple, mode: .dark)
        ]
    }

    // MARK: - The property that matters

    @Test("The styled string is exactly as long as the model text")
    func lengthMatchesModel() {
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            for theme in Self.themes {
                let styled = RichMarkdownStyler.attributedString(
                    for: model,
                    documentURL: nil,
                    colorTheme: theme
                )
                #expect(
                    styled.length == (model.text as NSString).length,
                    """
                    \(document.id) in \(theme.title): styled \(styled.length) \
                    vs model \((model.text as NSString).length)
                    """
                )
                #expect(styled.string == model.text)
            }
        }
    }

    /// No attribute may run past the end of the string it is attached to.
    ///
    /// `NSAttributedString` traps on an out-of-range attribute rather than
    /// ignoring it, so this is a crash on opening a document, not a cosmetic
    /// fault.
    @Test("No attribute run escapes the string")
    func attributeRunsStayInBounds() {
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            let styled = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: nil,
                colorTheme: EditorColorTheme(color: .blue, mode: .light)
            )
            var index = 0
            while index < styled.length {
                var effective = NSRange(location: 0, length: 0)
                let attributes = styled.attributes(
                    at: index,
                    effectiveRange: &effective
                )
                #expect(
                    effective.location >= 0
                        && NSMaxRange(effective) <= styled.length,
                    "\(document.id): run \(effective) escapes \(styled.length)"
                )
                #expect(
                    attributes[.font] != nil,
                    "\(document.id): no font at \(index)"
                )
                #expect(
                    attributes[.foregroundColor] != nil,
                    "\(document.id): no color at \(index)"
                )
                index = max(index + 1, NSMaxRange(effective))
            }
        }
    }

    @Test("Styling is deterministic")
    func stylingIsDeterministic() {
        let theme = EditorColorTheme(color: .brown, mode: .dark)
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            let first = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: nil,
                colorTheme: theme
            )
            let second = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: nil,
                colorTheme: theme
            )
            #expect(first.string == second.string)
            #expect(first.length == second.length)
        }
    }

    /// Every prefix, for the same reason the renderer is checked that way:
    /// this runs on half-typed markup all day.
    @Test("Every prefix styles without escaping its string")
    func prefixesStyleSafely() {
        let theme = EditorColorTheme(color: .blue, mode: .light)
        var checked = 0
        for document in ContractCorpus.documents {
            for index in document.text.indices {
                let prefix = String(document.text[..<index])
                let model = MarkdownRenderer.render(prefix)
                let styled = RichMarkdownStyler.attributedString(
                    for: model,
                    documentURL: nil,
                    colorTheme: theme
                )
                #expect(styled.length == (model.text as NSString).length)
                checked += 1
            }
        }
        #expect(checked > 1000, "only \(checked) prefixes were styled")
    }

    @Test("An empty document styles to an empty string")
    func emptyDocumentStylesEmpty() {
        let styled = RichMarkdownStyler.attributedString(
            for: MarkdownRenderer.render(""),
            documentURL: nil,
            colorTheme: EditorColorTheme(color: .blue, mode: .light)
        )
        #expect(styled.length == 0)
    }

    // MARK: - Image sizing

    /// The proportional sizing behind selecting an image and typing a width.
    ///
    /// Asking for one dimension has to derive the other from the real aspect
    /// ratio, which is the whole point of the feature: an image resized by
    /// width alone must not distort.
    @Test("A width alone keeps the aspect ratio")
    func widthAloneKeepsAspect() {
        let source = CGSize(width: 800, height: 400)
        let size = RichMarkdownStyler.displaySize(
            of: source,
            width: 200,
            height: nil
        )
        #expect(size.width == 200)
        #expect(size.height == 100)
    }

    @Test("A height alone keeps the aspect ratio")
    func heightAloneKeepsAspect() {
        let source = CGSize(width: 800, height: 400)
        let size = RichMarkdownStyler.displaySize(
            of: source,
            width: nil,
            height: 100
        )
        #expect(size.height == 100)
        #expect(size.width == 200)
    }

    @Test("Both dimensions are honoured exactly")
    func bothDimensionsAreHonoured() {
        let size = RichMarkdownStyler.displaySize(
            of: CGSize(width: 800, height: 400),
            width: 123,
            height: 456
        )
        #expect(size.width == 123)
        #expect(size.height == 456)
    }

    /// An unsized image is scaled to fit, and only ever down.
    @Test("An unsized image fits the page without being enlarged")
    func unsizedImagesFit() {
        let large = RichMarkdownStyler.displaySize(
            of: CGSize(width: 2000, height: 1000),
            width: nil,
            height: nil
        )
        #expect(large.width <= 560)
        #expect(large.height <= 380)
        // 2000x1000 is limited by width, so the ratio must survive.
        #expect(abs(large.width / large.height - 2) < 0.001)

        let small = RichMarkdownStyler.displaySize(
            of: CGSize(width: 100, height: 50),
            width: nil,
            height: nil
        )
        #expect(small.width == 100)
        #expect(small.height == 50)
    }

    /// A tall image must be limited by its height, not its width.
    @Test("A tall image is bounded by height")
    func tallImagesAreBoundedByHeight() {
        let size = RichMarkdownStyler.displaySize(
            of: CGSize(width: 400, height: 4000),
            width: nil,
            height: nil
        )
        #expect(size.height <= 380)
        #expect(size.width <= 560)
        #expect(abs(size.width / size.height - 0.1) < 0.001)
    }

    /// Sizes arrive from the document, where anything can be written, and
    /// from an image that failed to load and therefore has no size at all.
    /// None of it may produce a zero, a negative, or a NaN — all three are
    /// fatal to text layout.
    @Test("No input produces a degenerate size")
    func noInputProducesDegenerateSize() {
        let sources = [
            CGSize(width: 0, height: 0),
            CGSize(width: 0, height: 100),
            CGSize(width: 100, height: 0),
            CGSize(width: -100, height: -100),
            CGSize(width: 1, height: 1),
            CGSize(width: 10_000, height: 3)
        ]
        let requests: [(Int?, Int?)] = [
            (nil, nil), (0, nil), (nil, 0), (0, 0),
            (-5, nil), (nil, -5), (-5, -5), (1, nil), (nil, 1),
            (10_000, nil), (nil, 10_000), (10_000, 10_000)
        ]
        for source in sources {
            for (width, height) in requests {
                let size = RichMarkdownStyler.displaySize(
                    of: source,
                    width: width,
                    height: height
                )
                let request = "\(String(describing: width))x\(String(describing: height))"
                #expect(
                    size.width > 0 && size.height > 0,
                    "\(source) at \(request) gave \(size)"
                )
                #expect(
                    size.width.isFinite && size.height.isFinite,
                    "\(source) gave a non-finite \(size)"
                )
            }
        }
    }

    // MARK: - The column and the page's margins

    /// The paragraph style in force at `location`.
    private func indent(
        of styled: NSAttributedString,
        at location: Int
    ) -> CGFloat {
        let style = styled.attribute(
            .paragraphStyle, at: location, effectiveRange: nil
        ) as? NSParagraphStyle
        return style?.headIndent ?? 0
    }

    private func styled(
        _ source: String,
        page: MarkdownPageMetrics?
    ) -> NSAttributedString {
        RichMarkdownStyler.attributedString(
            for: MarkdownRenderer.render(source),
            documentURL: nil,
            colorTheme: EditorColorTheme(color: .blue, mode: .light),
            page: page
        )
    }

    @Test("Prose is indented to the column, not left across the page")
    func proseIsHeldToTheColumn() {
        let text = styled("Just a paragraph.", page: .init(measure: 642, bleed: 100))
        #expect(indent(of: text, at: 0) == 100)
    }

    @Test("A quote and a list keep their own indent on top of the column's")
    func blockIndentsAreRelativeToTheColumn() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        let quote = styled("> Quoted.", page: page)
        // 20 is the quote's own indent; it must sit inside the column, not
        // replace the indent that puts the column there in the first place.
        #expect(indent(of: quote, at: 0) == 120)

        let list = styled("- One", page: page)
        #expect(indent(of: list, at: 0) == 124)
    }

    @Test("Asking for no page leaves every indent exactly where it was")
    func noPageMeansNoChange() {
        #expect(indent(of: styled("Just a paragraph.", page: nil), at: 0) == 0)
        #expect(indent(of: styled("> Quoted.", page: nil), at: 0) == 20)
        #expect(indent(of: styled("- One", page: nil), at: 0) == 24)
    }

    @Test("A picture gives up its indent as it outgrows the column")
    func aPictureSpreadsIntoTheMargins() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        let attachmentIndent: (Int) -> CGFloat = { width in
            let text = self.styled(
                """
                Before.

                <img src="a.png" alt="a" width="\(width)" height="100">

                After.
                """,
                page: page
            )
            var found: CGFloat = -1
            text.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: text.length)
            ) { value, range, stop in
                guard value != nil else { return }
                found = self.indent(of: text, at: range.location)
                stop.pointee = true
            }
            return found
        }
        #expect(attachmentIndent(300) == 100)
        #expect(attachmentIndent(642) == 100)
        #expect(attachmentIndent(742) == 50)
        #expect(attachmentIndent(842) == 0)
    }

    @Test("A picture sitting in a sentence does not drag the words out with it")
    func anInlinePictureLeavesItsParagraphAlone() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        let text = styled(
            "Words <img src=\"a.png\" alt=\"a\" width=\"842\" height=\"100\"> more words.",
            page: page
        )
        // The paragraph holds prose as well, so it stays at the column however
        // wide the picture claims to be — otherwise the sentence around it
        // would be pulled into the margins too.
        #expect(indent(of: text, at: 0) == 100)
    }

    @Test("A picture is never drawn out of shape to fit the page")
    func fittingAPictureKeepsItsShape() {
        // TextKit's answer to a picture wider than its line is to squash it
        // horizontally and keep the height it was asked for. Measured on a
        // phone before this: a 1600x300 picture defaulting to 560 wide in a
        // 368pt column drew 384x107, where its own shape at that width is
        // 384x72. Scaling both sides is the only answer that keeps the picture
        // honest.
        let source = CGSize(width: 1_600, height: 300)
        let fitted = RichMarkdownStyler.displaySize(
            of: source, width: nil, height: nil, maximumWidth: 368
        )
        #expect(fitted.width == 368)
        #expect(abs(fitted.height - 368 * 300 / 1_600) < 0.5)
    }

    @Test("A size written into the document is fitted too, not squashed")
    func anAuthoredSizeIsScaledRatherThanCompressed() {
        // The document keeps the size it asked for — this only changes what is
        // drawn — but drawing it at a width the line cannot hold would squash
        // it, which is worse than drawing it smaller.
        let fitted = RichMarkdownStyler.displaySize(
            of: CGSize(width: 1_600, height: 300),
            width: 2_000, height: 375, maximumWidth: 400
        )
        #expect(fitted.width == 400)
        #expect(abs(fitted.height - 75) < 0.5, "the shape must survive")
    }

    @Test("A picture that already fits is left exactly alone")
    func fittingDoesNothingWhenThereIsRoom() {
        let asked = RichMarkdownStyler.displaySize(
            of: CGSize(width: 800, height: 400),
            width: 300, height: nil, maximumWidth: 842
        )
        #expect(asked.width == 300)
        #expect(asked.height == 150)
        // And with no ceiling at all, which is how every other caller uses it.
        let unbounded = RichMarkdownStyler.displaySize(
            of: CGSize(width: 800, height: 400), width: 300, height: nil
        )
        #expect(unbounded == asked)
    }
}
