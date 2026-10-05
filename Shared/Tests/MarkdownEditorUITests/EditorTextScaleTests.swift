#if canImport(AppKit)
import AppKit
import Foundation
import MarkdownEditorCore
import Testing
@testable import MarkdownEditorUI

/// How large the document is drawn — Customize Theme ▸ Size.
///
/// At 100% nothing may move: the default page is the page every earlier
/// release drew. Anywhere else the whole of the text's setting scales
/// together — type, line and paragraph spacing, the indents of lists, quotes
/// and code — while the pictures and the column stay exactly the size they
/// were.
@Suite("Editor text size")
struct EditorTextScaleTests {
    private static let document = """
        # Title

        plain **strong** and `inline`

        - item

        > quoted

        ```
        let code = 1
        ```
        """

    private static func styled(
        _ source: String = document,
        scale: CGFloat,
        typeface: EditorTypeface = .sans
    ) -> NSAttributedString {
        RichMarkdownStyler.attributedString(
            for: MarkdownRenderer.render(source),
            documentURL: nil,
            colorTheme: EditorColorTheme(
                color: .blue,
                mode: .light,
                typeface: typeface,
                textScale: scale
            )
        )
    }

    private static func attributes(
        of word: String,
        in text: NSAttributedString
    ) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: word)
        precondition(range.location != NSNotFound, "\(word) not rendered")
        return text.attributes(at: range.location, effectiveRange: nil)
    }

    private static func pointSize(
        of word: String,
        in text: NSAttributedString
    ) -> CGFloat {
        (attributes(of: word, in: text)[.font] as? NSFont)?.pointSize ?? 0
    }

    private static func paragraph(
        of word: String,
        in text: NSAttributedString
    ) -> NSParagraphStyle {
        attributes(of: word, in: text)[.paragraphStyle] as? NSParagraphStyle
            ?? NSParagraphStyle()
    }

    @Test("The default is 100%, and 100% draws the page exactly as before")
    func defaultIsUnchanged() {
        #expect(EditorColorTheme(color: .blue, mode: .light).textScale == 1)
        let text = Self.styled(scale: 1)
        #expect(Self.pointSize(of: "plain", in: text) == 15)
        #expect(Self.pointSize(of: "Title", in: text) == 30)
        #expect(Self.pointSize(of: "inline", in: text) == 13)
        #expect(Self.pointSize(of: "let code", in: text) == 13)
        let body = Self.paragraph(of: "plain", in: text)
        #expect(body.lineSpacing == 2)
        #expect(body.paragraphSpacing == 7)
        #expect(Self.paragraph(of: "item", in: text).headIndent == 24)
        #expect(Self.paragraph(of: "quoted", in: text).headIndent == 20)
        #expect(Self.paragraph(of: "let code", in: text).headIndent == 14)
    }

    @Test("Type, spacing and indents all scale together")
    func everythingScales() {
        for scale in [0.75, 1.25, 1.5] as [CGFloat] {
            let text = Self.styled(scale: scale)
            #expect(Self.pointSize(of: "plain", in: text) == 15 * scale)
            #expect(Self.pointSize(of: "strong", in: text) == 15 * scale)
            #expect(Self.pointSize(of: "Title", in: text) == 30 * scale)
            #expect(Self.pointSize(of: "inline", in: text) == 13 * scale)
            #expect(Self.pointSize(of: "let code", in: text) == 13 * scale)

            let body = Self.paragraph(of: "plain", in: text)
            #expect(body.lineSpacing == 2 * scale)
            #expect(body.paragraphSpacing == 7 * scale)
            let heading = Self.paragraph(of: "Title", in: text)
            #expect(heading.paragraphSpacingBefore == 14 * scale)
            #expect(heading.paragraphSpacing == 8 * scale)
            let item = Self.paragraph(of: "item", in: text)
            #expect(item.firstLineHeadIndent == 5 * scale)
            #expect(item.headIndent == 24 * scale)
            #expect(item.tabStops.map(\.location) == [24 * scale])
            #expect(Self.paragraph(of: "quoted", in: text).headIndent == 20 * scale)
            let code = Self.paragraph(of: "let code", in: text)
            #expect(code.headIndent == 14 * scale)
            #expect(code.paragraphSpacingBefore == 7 * scale)
        }
    }

    @Test("A chosen face is scaled on top of its own optical size")
    func scaleComposesWithTheFace() throws {
        let face = EditorTypeface.noteworthy
        try #require(face.isAvailable, "Noteworthy is not installed")
        let text = Self.styled("plain", scale: 1.5, typeface: face)
        let font = try #require(
            Self.attributes(of: "plain", in: text)[.font] as? NSFont
        )
        #expect(font.fontName == face.fontName)
        #expect(abs(font.pointSize - 15 * 1.5 * face.opticalScale) < 0.01)
    }

    @Test("A picture stays the size it was")
    func picturesDoNotScale() {
        func bounds(at scale: CGFloat) -> CGRect? {
            let text = Self.styled("![alt](missing.png)", scale: scale)
            var found: CGRect?
            text.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: text.length)
            ) { value, _, _ in
                found = (value as? NSTextAttachment)?.bounds
            }
            return found
        }
        #expect(bounds(at: 1) != nil)
        #expect(bounds(at: 1.5) == bounds(at: 1))
        #expect(bounds(at: 0.75) == bounds(at: 1))
    }

    @Test("The size is kept to 75–150%, in whole percent")
    func scaleIsClamped() {
        func scale(_ value: CGFloat) -> CGFloat {
            EditorColorTheme(color: .blue, mode: .light, textScale: value)
                .textScale
        }
        #expect(scale(0.5) == 0.75)
        #expect(scale(2) == 1.5)
        #expect(scale(.nan) == 1)
        #expect(scale(.infinity) == 1)
        #expect(scale(1.0000000000000002) == 1)
        #expect(scale(1.234) == 1.23)
        #expect(scale(0.75) == 0.75)
        #expect(scale(1.5) == 1.5)

        var theme = EditorColorTheme(color: .blue, mode: .light)
        theme.textScale = 3
        #expect(theme.textScale == 1.5)
        theme.textScale = 0.1
        #expect(theme.textScale == 0.75)
    }

    @Test("A different size is a different theme, so the page is re-styled")
    func sizeIsPartOfTheTheme() {
        let normal = EditorColorTheme(color: .blue, mode: .light)
        let larger = EditorColorTheme(
            color: .blue,
            mode: .light,
            textScale: 1.1
        )
        #expect(normal != larger)
        #expect(normal.hashValue != larger.hashValue)
        #expect(
            larger == EditorColorTheme(
                color: .blue,
                mode: .light,
                textScale: 1.1000000001
            )
        )
    }

    @Test("The size is remembered under its own key")
    func storageKeyIsItsOwn() {
        let keys: Set<String> = [
            EditorColorTheme.textScaleStorageKey,
            EditorColorTheme.typefaceStorageKey,
            EditorThemeColor.storageKey,
            EditorAppearanceMode.storageKey,
        ]
        #expect(keys.count == 4)
    }

    @Test("Bigger and Smaller step through the stops and stop at the ends")
    func steppingWalksTheStops() {
        var scale: CGFloat = 1
        var visited: [CGFloat] = []
        for _ in 0..<10 {
            scale = EditorColorTheme.steppedTextScale(from: scale, larger: true)
            visited.append(scale)
        }
        #expect(visited.prefix(5) == [1.1, 1.2, 1.3, 1.4, 1.5])
        #expect(visited.last == EditorColorTheme.textScaleRange.upperBound)

        scale = 1
        visited = []
        for _ in 0..<10 {
            scale = EditorColorTheme.steppedTextScale(from: scale, larger: false)
            visited.append(scale)
        }
        #expect(visited.prefix(3) == [0.9, 0.8, 0.75])
        #expect(visited.last == EditorColorTheme.textScaleRange.lowerBound)
    }

    @Test("A size between stops comes back to a round number on one press")
    func offGridSizesSnapToTheNextStop() {
        #expect(EditorColorTheme.steppedTextScale(from: 1.05, larger: true) == 1.1)
        #expect(EditorColorTheme.steppedTextScale(from: 1.05, larger: false) == 1)
        #expect(EditorColorTheme.steppedTextScale(from: 0.85, larger: false) == 0.8)
        // A value that has been through storage and come back a hair under
        // its stop is still on it, not one press behind.
        #expect(
            EditorColorTheme.steppedTextScale(from: 0.8999999, larger: true)
                == 1
        )
    }

    @Test("Every stop is a size the slider can show, and 100% is one of them")
    func stopsAreInRange() {
        for stop in EditorColorTheme.textScaleStops {
            #expect(EditorColorTheme.textScaleRange.contains(stop))
            #expect(EditorColorTheme.clampedTextScale(stop) == stop)
        }
        #expect(EditorColorTheme.textScaleStops.contains(1))
        #expect(
            EditorColorTheme.textScaleStops
                == EditorColorTheme.textScaleStops.sorted()
        )
    }
}
#endif
