import Foundation
import Testing
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import MarkdownEditorUI

/// A stand-in for the platform text view, so the styler can be exercised
/// without a window, a run loop, or a real `NSTextView`/`UITextView`.
@MainActor
private final class FakeSourceTextView: MarkdownSourceTextView {
    let storage: NSTextStorage
    let undo: UndoManager?
    private var resetDelegate: UndoResettingStorageDelegate?

    init(_ markdown: String, undo: UndoManager?, resetsUndoOnEdit: Bool = false) {
        storage = NSTextStorage(string: markdown)
        self.undo = undo
        if resetsUndoOnEdit, let undo {
            let delegate = UndoResettingStorageDelegate(undo: undo)
            resetDelegate = delegate
            storage.delegate = delegate
        }
    }

    var sourceTextStorage: NSTextStorage? { storage }
    var sourceText: String { storage.string }
    var sourceSelectionLocation: Int { 0 }
    var sourceTypingAttributes: [NSAttributedString.Key: Any] = [:]
    var sourceUndoManager: UndoManager? { undo }
}

/// Reproduces what UIKit does when a text view's storage is replaced: it
/// clears the undo stack, and `removeAllActions` also re-enables registration.
private final class UndoResettingStorageDelegate: NSObject, NSTextStorageDelegate {
    let undo: UndoManager

    init(undo: UndoManager) {
        self.undo = undo
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        undo.removeAllActions()
    }
}

@Suite("Markdown source styler")
@MainActor
struct MarkdownSourceStylerTests {
    private let theme = EditorColorTheme(color: .blue, mode: .light)

    /// Restyling one block must leave the storage exactly as a full restyle
    /// would, or the source pane grows a seam at the point of every edit.
    private func expectBlockRestyleMatchesWhole(
        _ markdown: String,
        changedRange: NSRange,
        label: String
    ) {
        let whole = FakeSourceTextView(markdown, undo: nil)
        MarkdownSourceStyler.apply(markdown, to: whole, colorTheme: theme)

        let partial = FakeSourceTextView(markdown, undo: nil)
        MarkdownSourceStyler.apply(markdown, to: partial, colorTheme: theme)
        MarkdownSourceStyler.restyle(
            blockContaining: changedRange,
            in: partial,
            colorTheme: theme
        )

        for index in 0..<whole.storage.length {
            let expected = whole.storage.attributes(at: index, effectiveRange: nil)
            let actual = partial.storage.attributes(at: index, effectiveRange: nil)
            let sameFont = (actual[.font] as? NSObject)?
                .isEqual(expected[.font]) ?? (expected[.font] == nil)
            let sameStyle = (actual[.paragraphStyle] as? NSObject)?
                .isEqual(expected[.paragraphStyle])
                ?? (expected[.paragraphStyle] == nil)
            #expect(sameFont, "\(label): the font differs at \(index)")
            #expect(sameStyle, "\(label): the paragraph style differs at \(index)")
            if !sameFont || !sameStyle { return }
        }
    }

    private static let blockStylingDocument = """
        # Title

        Some prose about the title, long enough to wrap.

        ## Subheading

        ```swift
        let value = 1
        ```

        ### Third level
        Closing prose.
        """

    @Test("Restyling a block matches restyling the document")
    func blockRestyleMatchesWhole() {
        let markdown = Self.blockStylingDocument
        let source = markdown as NSString
        for location in stride(from: 0, through: source.length, by: 3) {
            expectBlockRestyleMatchesWhole(
                markdown,
                changedRange: NSRange(location: location, length: 0),
                label: "caret at \(location)"
            )
        }
        expectBlockRestyleMatchesWhole(
            markdown,
            changedRange: NSRange(location: 2, length: source.length - 4),
            label: "a selection across the document"
        )
    }

    /// And it really does style: starting from nothing, the block comes back
    /// with the heading drawn as a heading.
    @Test("Restyling a block styles that block")
    func blockRestyleAppliesStyling() {
        let markdown = Self.blockStylingDocument
        let view = FakeSourceTextView(markdown, undo: nil)
        view.storage.setAttributes(
            MarkdownSourceStyler.baseAttributes(colorTheme: theme),
            range: NSRange(location: 0, length: view.storage.length)
        )
        let base = view.storage.attributes(at: 0, effectiveRange: nil)[.font]
            as? PlatformFont
        MarkdownSourceStyler.restyle(
            blockContaining: NSRange(location: 2, length: 0),
            in: view,
            colorTheme: theme
        )
        let styled = view.storage.attributes(at: 2, effectiveRange: nil)[.font]
            as? PlatformFont
        #expect(styled != nil)
        #expect(
            (styled?.pointSize ?? 0) > (base?.pointSize ?? 0),
            "the heading was not enlarged"
        )
        // And nothing outside the block moved.
        let tail = view.storage.attributes(
            at: view.storage.length - 1, effectiveRange: nil
        )[.font] as? PlatformFont
        #expect(tail?.pointSize == base?.pointSize)
    }

    @Test("Restyling a block leaves the characters alone")
    func blockRestyleDoesNotTouchCharacters() {
        let markdown = "# Title\n\nBody.\n\n```\ncode\n```\n"
        let view = FakeSourceTextView(markdown, undo: nil)
        MarkdownSourceStyler.restyle(
            blockContaining: NSRange(location: 3, length: 0),
            in: view,
            colorTheme: theme
        )
        #expect(view.storage.string == markdown)
    }

    @Test("Styling does not register an undoable action")
    func stylingIsNotUndoable() {
        let undo = UndoManager()
        let view = FakeSourceTextView("# Title\n\nBody", undo: undo)

        MarkdownSourceStyler.apply(view.sourceText, to: view, colorTheme: theme)

        #expect(undo.canUndo == false)
        #expect(undo.isUndoRegistrationEnabled)
    }

    /// The crash this guards against took down the whole Markdown pane on iOS
    /// the first time it was shown, because `enableUndoRegistration` throws
    /// when registration is already enabled.
    @Test("A text view that resets its undo manager mid-edit does not crash")
    func survivesUndoManagerResetDuringEdit() {
        let undo = UndoManager()
        let view = FakeSourceTextView(
            "# Title\n\n- One\n- Two",
            undo: undo,
            resetsUndoOnEdit: true
        )

        MarkdownSourceStyler.apply(view.sourceText, to: view, colorTheme: theme)

        #expect(undo.isUndoRegistrationEnabled)
        #expect(view.sourceText == "# Title\n\n- One\n- Two")
    }

    @Test("Registration already disabled by a caller is left disabled")
    func doesNotEnableRegistrationItDidNotDisable() {
        let undo = UndoManager()
        undo.disableUndoRegistration()
        let view = FakeSourceTextView("Body", undo: undo)

        MarkdownSourceStyler.apply(view.sourceText, to: view, colorTheme: theme)

        #expect(undo.isUndoRegistrationEnabled == false)
        undo.enableUndoRegistration()
    }

    @Test("A text view with no undo manager still gets styled")
    func worksWithoutAnUndoManager() {
        let view = FakeSourceTextView("# Title", undo: nil)

        MarkdownSourceStyler.apply(view.sourceText, to: view, colorTheme: theme)

        #expect(view.sourceText == "# Title")
        #expect(view.sourceTypingAttributes.isEmpty == false)
    }
}
