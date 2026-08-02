import AppKit
import MarkdownEditorCore
import SwiftUI

struct SourceTextEditor: NSViewRepresentable {
    @Binding var text: String
    let session: MarkdownEditorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = RichMarkdownTextView(frame: scrollView.bounds)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.string = text
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 18, height: 16)
        textView.setAccessibilityLabel("Markdown source")

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        textView.compositionDidBegin = {
            [weak coordinator = context.coordinator] range in
            coordinator?.beginComposition(replacing: range)
        }
        textView.compositionDidCommit = {
            [weak coordinator = context.coordinator] in
            coordinator?.commitComposition()
        }
        textView.markdownForRenderedRange = {
            [weak coordinator = context.coordinator] range in
            coordinator?.markdown(in: range) ?? ""
        }
        textView.replaceSelectionWithMarkdown = {
            [weak coordinator = context.coordinator] markdown, actionName in
            coordinator?.replaceSelection(
                with: markdown,
                actionName: actionName
            )
        }
        session.attach(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }

        context.coordinator.text = $text
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let textLength = textView.string.utf16.count
            let selectionLocation = min(selection.location, textLength)
            let selectionLength = min(
                selection.length,
                textLength - selectionLocation
            )
            textView.setSelectedRange(
                NSRange(
                    location: selectionLocation,
                    length: selectionLength
                )
            )
        }

        if context.coordinator.textView !== textView {
            context.coordinator.textView = textView
        }
        session.attach(context.coordinator)
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView
            as? RichMarkdownTextView
        else {
            return
        }
        textView.finishPendingComposition()
        coordinator.session?.detach(coordinator)
        textView.delegate = nil
        textView.compositionDidBegin = nil
        textView.compositionDidCommit = nil
        textView.markdownForRenderedRange = nil
        textView.replaceSelectionWithMarkdown = nil
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate,
        MarkdownEditingSurface
    {
        var text: Binding<String>
        weak var session: MarkdownEditorSession?
        weak var textView: NSTextView?
        private var isApplyingChange = false
        private var compositionState: SourceCompositionState?

        init(text: Binding<String>, session: MarkdownEditorSession) {
            self.text = text
            self.session = session
        }

        var sourceText: String {
            text.wrappedValue
        }

        var selectedSourceRange: NSRange {
            guard let textView else {
                return NSRange(location: 0, length: 0)
            }
            return textView.selectedRange()
        }

        var hostingWindow: NSWindow? {
            textView?.window
        }

        var hasFocus: Bool {
            guard let textView else {
                return false
            }
            return textView.window?.firstResponder === textView
        }

        func apply(_ result: MarkdownEditResult, actionName: String) {
            let previousState = MarkdownEditResult(
                text: text.wrappedValue,
                selection: selectedSourceRange
            )
            set(result)
            if let undoManager = textView?.undoManager {
                session?.registerUndo(
                    previousState,
                    actionName: actionName,
                    undoManager: undoManager
                )
            }
        }

        func restore(_ result: MarkdownEditResult) {
            set(result)
        }

        func commitPendingComposition() {
            (textView as? RichMarkdownTextView)?
                .finishPendingComposition()
        }

        func setSourceSelection(_ selection: NSRange) {
            guard let textView else {
                return
            }
            let length = (textView.string as NSString).length
            let location = min(max(0, selection.location), length)
            textView.setSelectedRange(
                NSRange(
                    location: location,
                    length: min(
                        max(0, selection.length),
                        length - location
                    )
                )
            )
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        func focus() {
            guard let textView else {
                return
            }
            textView.window?.makeFirstResponder(textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            session?.activate(self)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if hasFocus {
                session?.activate(self)
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingChange else {
                return true
            }
            if let markdownTextView = textView as? RichMarkdownTextView,
                markdownTextView.isUpdatingComposition
            {
                return true
            }
            guard let replacementString else {
                return false
            }

            replace(
                range: affectedCharRange,
                with: replacementString,
                actionName: "Edit"
            )
            return false
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingChange,
                !((notification.object as? RichMarkdownTextView)?
                    .isUpdatingComposition ?? false)
            else {
                return
            }
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }

        func beginComposition(replacing range: NSRange) {
            guard let textView, compositionState == nil else {
                return
            }
            let safeRange = clamped(
                range,
                to: (textView.string as NSString).length
            )
            compositionState = SourceCompositionState(
                sourceText: text.wrappedValue,
                sourceSelection: safeRange,
                displayedText: textView.string,
                displayedRange: safeRange
            )
        }

        func commitComposition() {
            guard let textView, let compositionState else {
                return
            }
            self.compositionState = nil
            let oldText = compositionState.displayedText as NSString
            let newText = textView.string as NSString
            if oldText.isEqual(to: newText as String) {
                set(
                    MarkdownEditResult(
                        text: compositionState.sourceText,
                        selection: compositionState.sourceSelection
                    )
                )
                return
            }
            let difference = MarkdownTextDifference.replacement(
                from: oldText as String,
                to: newText as String,
                replacing: compositionState.displayedRange
            )
            guard !difference.replacement.contains("\u{FFFC}") else {
                NSSound.beep()
                set(
                    MarkdownEditResult(
                        text: compositionState.sourceText,
                        selection: compositionState.sourceSelection
                    )
                )
                return
            }

            let mutableSource = NSMutableString(
                string: compositionState.sourceText
            )
            let range = clamped(
                difference.range,
                to: mutableSource.length
            )
            mutableSource.replaceCharacters(
                in: range,
                with: difference.replacement
            )
            let result = MarkdownEditResult(
                text: mutableSource as String,
                selection: NSRange(
                    location: range.location
                        + (difference.replacement as NSString).length,
                    length: 0
                )
            )
            set(result)
            if let undoManager = textView.undoManager {
                session?.registerUndo(
                    MarkdownEditResult(
                        text: compositionState.sourceText,
                        selection: compositionState.sourceSelection
                    ),
                    actionName: "Edit",
                    undoManager: undoManager
                )
            }
        }

        func markdown(in range: NSRange) -> String {
            let source = text.wrappedValue as NSString
            return source.substring(
                with: clamped(range, to: source.length)
            )
        }

        func replaceSelection(
            with replacement: String,
            actionName: String
        ) {
            replace(
                range: selectedSourceRange,
                with: replacement,
                actionName: actionName
            )
        }

        private func replace(
            range: NSRange,
            with replacement: String,
            actionName: String
        ) {
            guard !replacement.contains("\u{FFFC}") else {
                NSSound.beep()
                return
            }
            let source = NSMutableString(string: text.wrappedValue)
            let safeRange = clamped(range, to: source.length)
            source.replaceCharacters(in: safeRange, with: replacement)
            apply(
                MarkdownEditResult(
                    text: source as String,
                    selection: NSRange(
                        location: safeRange.location
                            + (replacement as NSString).length,
                        length: 0
                    )
                ),
                actionName: actionName
            )
        }

        private func set(_ result: MarkdownEditResult) {
            isApplyingChange = true
            text.wrappedValue = result.text
            textView?.string = result.text
            setSourceSelection(result.selection)
            isApplyingChange = false
        }

        private func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            return NSRange(
                location: location,
                length: min(max(0, range.length), length - location)
            )
        }
    }
}

private struct SourceCompositionState {
    let sourceText: String
    let sourceSelection: NSRange
    let displayedText: String
    let displayedRange: NSRange
}
