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

/// Styling a block on its own has to give the same attributes as styling the
/// document it belongs to.
///
/// This is the half of "never re-render the whole document" that the editor
/// actually shows. The renderer decides *what* changed; this decides what the
/// reader sees, and if a fragment styled alone differs by so much as a
/// paragraph indent then typing would leave a visible seam in the document at
/// the point of every edit.
@Suite("Incremental styling")
struct RichMarkdownStylerFragmentTests {
    private static var themes: [EditorColorTheme] {
        [
            EditorColorTheme(color: .blue, mode: .light),
            EditorColorTheme(color: .purple, mode: .dark)
        ]
    }

    private static let page = MarkdownPageMetrics(measure: 640, bleed: 80)

    /// The document styled in one piece, in the same kind of storage the
    /// editor keeps it in.
    ///
    /// Through a storage rather than as a bare attributed string because
    /// `NSTextStorage` normalises what it is given — it makes a paragraph
    /// style uniform across its paragraph, and it substitutes a font that
    /// cannot draw a character. Comparing a spliced storage against a bare
    /// string would be comparing those rules rather than the styler.
    private static func wholeDocumentStorage(
        _ source: String,
        theme: EditorColorTheme,
        page: MarkdownPageMetrics?
    ) -> NSTextStorage {
        let storage = SimpleTextStorage()
        storage.setAttributedString(
            RichMarkdownStyler.attributedString(
                for: MarkdownRenderer.render(source),
                documentURL: nil,
                colorTheme: theme,
                page: page
            )
        )
        return storage
    }

    /// Rebuilds a document out of its blocks and compares it, attribute by
    /// attribute, with the same document styled in one piece.
    private static func expectFragmentsMatchWhole(
        _ source: String,
        theme: EditorColorTheme,
        page: MarkdownPageMetrics?,
        label: String
    ) {
        let whole = wholeDocumentStorage(source, theme: theme, page: page)

        // Built the way the editor builds it: start from nothing and splice in
        // one block at a time, exactly as a keystroke would.
        let renderer = MarkdownIncrementalRenderer(source: "")
        let assembled = SimpleTextStorage()
        let update = renderer.update(source: source)
        assembled.beginEditing()
        assembled.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: RichMarkdownStyler.attributedString(
                forFragment: update.fragment,
                spans: update.spans,
                documentURL: nil,
                colorTheme: theme,
                page: page
            )
        )
        assembled.endEditing()

        #expect(
            assembled.string == whole.string,
            "\(label): the assembled text differs"
        )
        guard assembled.string == whole.string else { return }
        if let complaint = firstAttributeDifference(assembled, whole) {
            Issue.record("\(label): \(complaint)")
        }
    }

    private static func firstAttributeDifference(
        _ actual: NSAttributedString,
        _ expected: NSAttributedString
    ) -> String? {
        for index in 0..<expected.length {
            let mine = actual.attributes(at: index, effectiveRange: nil)
            let theirs = expected.attributes(at: index, effectiveRange: nil)
            if let key = differingKey(mine, theirs) {
                return """
                    \(key.rawValue) differs at \(index): \
                    \(String(describing: mine[key])) rather than \
                    \(String(describing: theirs[key]))
                    """
            }
        }
        return nil
    }

    /// Attribute dictionaries are not `Equatable`, and two of the values in
    /// them are reference types that are never the same object twice, so this
    /// compares what is actually being asserted.
    private static func differingKey(
        _ mine: [NSAttributedString.Key: Any],
        _ theirs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString.Key? {
        let keys = Set(mine.keys).union(theirs.keys)
        for key in keys {
            let a = mine[key]
            let b = theirs[key]
            if a == nil || b == nil {
                return key
            }
            if key == .attachment {
                // Two attachments for the same picture are different objects;
                // what has to match is the size they are drawn at.
                let left = (a as? NSTextAttachment)?.bounds ?? .zero
                let right = (b as? NSTextAttachment)?.bounds ?? .zero
                if left != right { return key }
                continue
            }
            if let left = a as? PlatformColor, let right = b as? PlatformColor {
                // The same colour can be held in two colour spaces — the
                // storage converts what it is given, and which space that is
                // depends on the appearance in force at the time. Compare what
                // the reader sees rather than how it happens to be written
                // down.
                if !sameColour(left, right) { return key }
                continue
            }
            guard let left = a as? NSObject, let right = b as? NSObject else {
                return key
            }
            if !left.isEqual(right) { return key }
        }
        return nil
    }

    private static func sameColour(
        _ left: PlatformColor,
        _ right: PlatformColor
    ) -> Bool {
        guard let a = components(of: left), let b = components(of: right) else {
            return left.isEqual(right)
        }
        return zip(a, b).allSatisfy { abs($0 - $1) < 0.01 }
    }

    private static func components(of colour: PlatformColor) -> [CGFloat]? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let converted = colour.usingColorSpace(.sRGB) else { return nil }
        return [
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent
        ]
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        else { return nil }
        return [red, green, blue, alpha]
        #endif
    }

    @Test("Every corpus document styles the same in blocks as in one piece")
    func corpusMatches() {
        for document in ContractCorpus.documents {
            for theme in Self.themes {
                Self.expectFragmentsMatchWhole(
                    document.text,
                    theme: theme,
                    page: Self.page,
                    label: "\(document.id) with a page"
                )
                Self.expectFragmentsMatchWhole(
                    document.text,
                    theme: theme,
                    page: nil,
                    label: "\(document.id) with no page"
                )
            }
        }
    }

    @Test("Typing into a document leaves no seam where the block was replaced")
    func typingLeavesNoSeam() {
        let theme = Self.themes[0]
        let source = """
        # Notes

        A paragraph with **bold** in it.

        - [ ] a task
        - a bullet

        > a quote

        ```swift
        let value = 1
        ```

        The last paragraph.
        """

        let renderer = MarkdownIncrementalRenderer(source: source)
        let storage = SimpleTextStorage()
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: RichMarkdownStyler.attributedString(
                forFragment: renderer.renderedText(),
                spans: renderer.allSpans(),
                documentURL: nil,
                colorTheme: theme,
                page: Self.page
            )
        )
        storage.endEditing()

        var current = source
        // One edit in each kind of block, applied the way the editor does it.
        for location in [2, 12, 40, 62, 80, 100, (source as NSString).length - 3] {
            let range = NSRange(location: location, length: 0)
            let update = renderer.replace(sourceRange: range, with: "x")
            current = (current as NSString)
                .replacingCharacters(in: range, with: "x")
            storage.beginEditing()
            storage.replaceCharacters(
                in: update.renderedRange,
                with: RichMarkdownStyler.attributedString(
                    forFragment: update.fragment,
                    spans: update.spans,
                    documentURL: nil,
                    colorTheme: theme,
                    page: Self.page
                )
            )
            storage.endEditing()

            let whole = Self.wholeDocumentStorage(
                current,
                theme: theme,
                page: Self.page
            )
            #expect(
                storage.string == whole.string,
                "text differs after typing at \(location)"
            )
            guard storage.string == whole.string else { return }
            if let complaint = Self.firstAttributeDifference(storage, whole) {
                #expect(Bool(false), "after typing at \(location): \(complaint)")
                return
            }
        }
    }
}

/// A plain text storage, so the splice being tested is the same call the
/// editor makes rather than a stand-in for it.
private final class SimpleTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()

    override var string: String { backing.string }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with string: String) {
        backing.replaceCharacters(in: range, with: string)
        edited(
            .editedCharacters,
            range: range,
            changeInLength: (string as NSString).length - range.length
        )
    }

    override func setAttributes(
        _ attributes: [NSAttributedString.Key: Any]?,
        range: NSRange
    ) {
        backing.setAttributes(attributes, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
    }
}
