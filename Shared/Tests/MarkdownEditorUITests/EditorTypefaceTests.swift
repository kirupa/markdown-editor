#if canImport(AppKit)
import AppKit
import CoreText
import Foundation
import MarkdownEditorCore
import Testing
@testable import MarkdownEditorUI

/// The face the document is set in — Customize Theme ▸ Font.
///
/// The list is the critique's hand list moved into the shared package, so the
/// first thing held is that the move changed nothing anybody had stored. The
/// rest is what choosing a face has to do to the page, and — as importantly —
/// what not choosing one must leave exactly as it was.
@Suite("Editor typeface")
struct EditorTypefaceTests {
    private static func styled(
        _ source: String,
        in typeface: EditorTypeface
    ) -> NSAttributedString {
        RichMarkdownStyler.attributedString(
            for: MarkdownRenderer.render(source),
            documentURL: nil,
            colorTheme: EditorColorTheme(
                color: .blue,
                mode: .light,
                typeface: typeface
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

    /// A bundled face with genuinely one weight, loaded the way the app
    /// bundle's `ATSApplicationFontsPath` would load it — the test process has
    /// no bundle. Not Caveat: the bundled Caveat is a variable font with a real
    /// bold, which AppKit finds and which is therefore used, not drawn.
    private static let patrickHandRegistered: Bool = {
        let font = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("macOS/Packaging/Fonts/PatrickHand-Regular.ttf")
        CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        return NSFont(name: EditorTypeface.patrickHand.fontName, size: 12) != nil
    }()

    @Test("The stored names are the ones the critique already saved")
    func rawValuesUnchanged() {
        #expect(EditorTypeface.allCases.map(\.rawValue) == [
            "sans", "architectsDaughter", "caveat", "indieFlower",
            "patrickHand", "shadowsIntoLight", "gloriaHallelujah", "kalam",
            "permanentMarker", "bradleyHand", "markerFelt", "noteworthy",
            "chalkboard", "qeDaveMergens", "qeJulianDean",
        ])
        #expect(
            EditorColorTheme(color: .blue, mode: .light).typeface == .sans
        )
        #expect(EditorColorTheme.typefaceStorageKey != "critiqueHandFont")
    }

    @Test("A different face is a different theme, so the page is re-styled")
    func faceIsPartOfTheTheme() {
        #expect(
            EditorColorTheme(color: .blue, mode: .light)
                != EditorColorTheme(color: .blue, mode: .light, typeface: .caveat)
        )
    }

    @Test("The system face draws the document exactly as it always has")
    func defaultUnchanged() {
        let text = Self.styled("# Title\n\nplain **strong** *leaning*", in: .sans)
        let body = Self.attributes(of: "plain", in: text)
        #expect(
            body[.font] as? NSFont == NSFont.systemFont(ofSize: 15)
        )
        #expect(
            Self.attributes(of: "Title", in: text)[.font] as? NSFont
                == NSFont.systemFont(ofSize: 30, weight: .bold)
        )
        let strong = Self.attributes(of: "strong", in: text)
        let leaning = Self.attributes(of: "leaning", in: text)
        #expect(strong[.strokeWidth] == nil)
        #expect(leaning[.obliqueness] == nil)
        #expect(
            NSFontManager.shared.traits(of: strong[.font] as! NSFont)
                .contains(.boldFontMask)
        )
    }

    @Test("A chosen face sets the body and the headings, at its optical size")
    func chosenFaceSetsPage() throws {
        let face = EditorTypeface.noteworthy
        try #require(face.isAvailable, "Noteworthy is not installed")
        let text = Self.styled("# Title\n\nplain", in: face)
        let body = try #require(
            Self.attributes(of: "plain", in: text)[.font] as? NSFont
        )
        let heading = try #require(
            Self.attributes(of: "Title", in: text)[.font] as? NSFont
        )
        #expect(body.fontName == face.fontName)
        #expect(abs(body.pointSize - 15 * face.opticalScale) < 0.01)
        #expect(heading.fontName == face.fontName)
        #expect(abs(heading.pointSize - 30 * face.opticalScale) < 0.01)
    }

    @Test("Emphasis in a face with one weight is drawn rather than dropped")
    func singleWeightEmphasisIsDrawn() throws {
        try #require(Self.patrickHandRegistered, "could not load Patrick Hand")
        let text = Self.styled("plain **strong** *leaning*", in: .patrickHand)
        let plain = Self.attributes(of: "plain", in: text)
        let strong = Self.attributes(of: "strong", in: text)
        let leaning = Self.attributes(of: "leaning", in: text)

        #expect((plain[.font] as? NSFont)?.fontName == "PatrickHand-Regular")
        #expect((strong[.font] as? NSFont)?.fontName == "PatrickHand-Regular")
        #expect(plain[.strokeWidth] == nil)
        #expect(plain[.obliqueness] == nil)
        #expect((strong[.strokeWidth] as? CGFloat ?? 0) < 0)
        #expect((leaning[.obliqueness] as? CGFloat ?? 0) > 0)
    }

    @Test("A face that has a bold uses it instead of drawing one")
    func realBoldPreferred() throws {
        let face = EditorTypeface.noteworthy
        try #require(face.isAvailable, "Noteworthy is not installed")
        let strong = Self.attributes(
            of: "strong",
            in: Self.styled("plain **strong**", in: face)
        )
        let font = try #require(strong[.font] as? NSFont)
        #expect(font.fontName != face.fontName)
        #expect(strong[.strokeWidth] == nil)
    }

    @Test("A face whose licence forbids shipping it is only ever found")
    func unshippableFacesAreNeverBundled() {
        for face in [EditorTypeface.qeDaveMergens, .qeJulianDean] {
            #expect(!face.isBundled, "\(face.title)")
            #expect(
                face.isAvailable
                    == (NSFont(name: face.fontName, size: 12) != nil),
                "\(face.title) is offered only where it is installed"
            )
            #expect(
                EditorTypeface.available.contains(face) == face.isAvailable,
                "\(face.title)"
            )
        }
    }

    @Test("A face that cannot be found draws in the system face")
    func missingFaceFallsBack() {
        for face in EditorTypeface.allCases where !face.isAvailable {
            #expect(
                face.font(ofSize: 15) == NSFont.systemFont(ofSize: 15),
                "\(face.title)"
            )
        }
        #expect(EditorTypeface.available.first == .sans)
    }
}
#endif
