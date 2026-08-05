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
