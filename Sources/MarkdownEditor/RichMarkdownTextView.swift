import AppKit

@MainActor
final class RichMarkdownTextView: NSTextView {
    static let markdownPasteboardType = NSPasteboard.PasteboardType(
        "com.kirupa.markdown-editor.source"
    )

    var compositionDidBegin: ((NSRange) -> Void)?
    var compositionDidCommit: (() -> Void)?
    var markdownForRenderedRange: ((NSRange) -> String)?
    var replaceSelectionWithMarkdown: ((String, String) -> Void)?

    private(set) var isUpdatingComposition = false
    private var compositionIsActive = false
    private weak var compositionUndoManager: UndoManager?

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if !compositionIsActive {
            compositionIsActive = true
            compositionUndoManager = undoManager
            compositionUndoManager?.disableUndoRegistration()
            let range = replacementRange.location == NSNotFound
                ? self.selectedRange()
                : replacementRange
            compositionDidBegin?(range)
        }

        isUpdatingComposition = true
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
    }

    override func insertText(
        _ insertString: Any,
        replacementRange: NSRange
    ) {
        guard compositionIsActive else {
            super.insertText(
                insertString,
                replacementRange: replacementRange
            )
            return
        }

        isUpdatingComposition = true
        super.insertText(
            insertString,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
        finishComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        if !isUpdatingComposition {
            finishComposition()
        }
    }

    func finishPendingComposition() {
        guard compositionIsActive else {
            return
        }
        isUpdatingComposition = true
        super.unmarkText()
        isUpdatingComposition = false
        finishComposition()
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0,
            let markdown = markdownForRenderedRange?(selection)
        else {
            super.copy(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            markdown,
            forType: Self.markdownPasteboardType
        )
        pasteboard.setString(markdown, forType: .string)
    }

    override func cut(_ sender: Any?) {
        finishPendingComposition()
        guard selectedRange().length > 0 else {
            return
        }
        copy(sender)
        replaceSelectionWithMarkdown?("", "Cut")
    }

    override func paste(_ sender: Any?) {
        finishPendingComposition()
        let pasteboard = NSPasteboard.general
        if let markdown = pasteboard.string(
            forType: Self.markdownPasteboardType
        ) {
            replaceSelectionWithMarkdown?(markdown, "Paste")
            return
        }
        if let plainText = pasteboard.string(forType: .string) {
            insertText(plainText, replacementRange: selectedRange())
            return
        }

        NSSound.beep()
    }

    private func finishComposition() {
        guard compositionIsActive else {
            return
        }
        compositionIsActive = false
        compositionUndoManager?.enableUndoRegistration()
        compositionUndoManager = nil
        compositionDidCommit?()
    }
}
