import AppKit
import MarkdownEditorCore
import SwiftUI

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let documentURL: URL?
    let session: MarkdownEditorSession
    let layoutWidth: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            documentURL: documentURL,
            session: session
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ReflowingTextScrollView()
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

        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.setAccessibilityLabel("Rendered Markdown editor")
        scrollView.requestedDocumentWidth = layoutWidth

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.textView = textView
        context.coordinator.observeScrolling(in: scrollView)
        textView.compositionDidBegin = {
            [weak coordinator = context.coordinator] range in
            coordinator?.beginComposition(replacing: range)
        }
        textView.compositionDidCommit = { [weak coordinator = context.coordinator] in
            coordinator?.commitComposition()
        }
        textView.markdownForRenderedRange = {
            [weak coordinator = context.coordinator] range in
            coordinator?.markdown(forRenderedRange: range) ?? ""
        }
        textView.replaceSelectionWithMarkdown = {
            [weak coordinator = context.coordinator] markdown, actionName in
            coordinator?.replaceSelection(
                withMarkdown: markdown,
                actionName: actionName
            )
        }
        context.coordinator.render(
            sourceSelection: NSRange(location: 0, length: 0)
        )
        session.attach(context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        context.coordinator.textView = textView
        context.coordinator.update(
            text: $text,
            documentURL: documentURL
        )
        (scrollView as? ReflowingTextScrollView)?
            .requestedDocumentWidth = layoutWidth
        session.attach(context.coordinator)
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        if let textView = scrollView.documentView as? RichMarkdownTextView {
            textView.finishPendingComposition()
        }
        coordinator.session?.detach(coordinator)
        if let textView = scrollView.documentView as? RichMarkdownTextView {
            textView.delegate = nil
            textView.compositionDidBegin = nil
            textView.compositionDidCommit = nil
            textView.markdownForRenderedRange = nil
            textView.replaceSelectionWithMarkdown = nil
        }
        coordinator.stopObservingScrolling()
        coordinator.textView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate,
        MarkdownEditingSurface
    {
        var text: Binding<String>
        var documentURL: URL?
        weak var session: MarkdownEditorSession?
        weak var textView: NSTextView?

        private var model = MarkdownRenderer.render("")
        private var renderedSource = ""
        private var renderedDocumentURL: URL?
        private var isRendering = false
        private var compositionState: CompositionState?
        private let scrollSynchronizer = EditorScrollSynchronizer()

        init(
            text: Binding<String>,
            documentURL: URL?,
            session: MarkdownEditorSession
        ) {
            self.text = text
            self.documentURL = documentURL
            self.session = session
        }

        var sourceText: String {
            text.wrappedValue
        }

        var selectedSourceRange: NSRange {
            guard let textView else {
                return NSRange(location: 0, length: 0)
            }
            return model.sourceRange(for: textView.selectedRange())
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

        var normalizedScrollPosition: CGFloat {
            scrollSynchronizer.normalizedPosition
        }

        func observeScrolling(in scrollView: NSScrollView) {
            scrollSynchronizer.attach(to: scrollView)
            scrollSynchronizer.didScroll = { [weak self] position in
                guard let self else {
                    return
                }
                session?.synchronizeScroll(from: self, position: position)
            }
        }

        func stopObservingScrolling() {
            scrollSynchronizer.didScroll = nil
            scrollSynchronizer.detach()
        }

        func update(text: Binding<String>, documentURL: URL?) {
            self.text = text
            self.documentURL = documentURL
            guard renderedSource != text.wrappedValue
                || renderedDocumentURL != documentURL
            else {
                return
            }

            let selection = selectedSourceRange
            let scrollPosition = normalizedScrollPosition
            render(
                sourceSelection: selection,
                scrollToSelection: false
            )
            setNormalizedScrollPosition(scrollPosition)
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
            setSourceSelection(selection, scrollToSelection: true)
        }

        func setNormalizedScrollPosition(_ position: CGFloat) {
            scrollSynchronizer.setNormalizedPosition(position)
        }

        private func setSourceSelection(
            _ selection: NSRange,
            scrollToSelection: Bool
        ) {
            guard let textView else {
                return
            }
            let renderedSelection = clamped(
                model.renderedRange(for: selection),
                to: (textView.string as NSString).length
            )
            textView.setSelectedRange(renderedSelection)
            if scrollToSelection {
                textView.scrollRangeToVisible(renderedSelection)
            }
        }

        func focus() {
            guard let textView else {
                return
            }
            textView.window?.makeFirstResponder(textView)
        }

        func render(
            sourceSelection: NSRange,
            scrollToSelection: Bool = true
        ) {
            guard let textView else {
                return
            }

            isRendering = true
            model = MarkdownRenderer.render(text.wrappedValue)
            let attributedText = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: documentURL
            )
            textView.textStorage?.setAttributedString(attributedText)
            renderedSource = text.wrappedValue
            renderedDocumentURL = documentURL
            setSourceSelection(
                sourceSelection,
                scrollToSelection: scrollToSelection
            )
            isRendering = false
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
            guard !isRendering else {
                return true
            }
            if let richTextView = textView as? RichMarkdownTextView,
                richTextView.isUpdatingComposition
            {
                return true
            }
            guard let replacementString else {
                return false
            }

            let sourceRange = model.sourceRange(
                for: clamped(
                    affectedCharRange,
                    to: (textView.string as NSString).length
                )
            )
            let replacement = replacementString
            if replacement == "\n" {
                if isInsideCodeBlock(sourceRange.location) {
                    replaceSource(
                        range: sourceRange,
                        with: replacement,
                        actionName: "Insert Newline"
                    )
                } else {
                    apply(
                        MarkdownFormatting.insertNewline(
                            in: text.wrappedValue,
                            selection: sourceRange
                        ),
                        actionName: "Insert Newline"
                    )
                }
                return false
            }

            guard !replacement.contains("\u{FFFC}") else {
                NSSound.beep()
                return false
            }
            replaceSource(
                range: sourceRange,
                with: replacement,
                actionName: "Edit"
            )
            return false
        }

        func beginComposition(replacing renderedRange: NSRange) {
            guard let textView, compositionState == nil else {
                return
            }
            let safeRenderedRange = clamped(
                renderedRange,
                to: (textView.string as NSString).length
            )
            compositionState = CompositionState(
                sourceText: text.wrappedValue,
                sourceSelection: model.sourceRange(for: safeRenderedRange),
                renderedText: textView.string,
                renderedRange: safeRenderedRange,
                model: model
            )
        }

        func commitComposition() {
            guard let textView, let compositionState else {
                return
            }
            self.compositionState = nil

            let oldText = compositionState.renderedText as NSString
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
                replacing: compositionState.renderedRange
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
            let sourceRange = compositionState.model.sourceRange(
                for: difference.range
            )
            let mutableSource = NSMutableString(
                string: compositionState.sourceText
            )
            mutableSource.replaceCharacters(
                in: clamped(sourceRange, to: mutableSource.length),
                with: difference.replacement
            )
            let result = MarkdownEditResult(
                text: mutableSource as String,
                selection: NSRange(
                    location: sourceRange.location
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

        func markdown(forRenderedRange range: NSRange) -> String {
            let source = text.wrappedValue as NSString
            let sourceRange = clamped(
                model.sourceRange(for: range, includingMarkup: true),
                to: source.length
            )
            return source.substring(with: sourceRange)
        }

        func replaceSelection(
            withMarkdown markdown: String,
            actionName: String
        ) {
            replaceSource(
                range: selectedSourceRange,
                with: markdown,
                actionName: actionName
            )
        }

        private func set(_ state: MarkdownEditResult) {
            let scrollPosition = normalizedScrollPosition
            text.wrappedValue = state.text
            render(
                sourceSelection: state.selection,
                scrollToSelection: false
            )
            setNormalizedScrollPosition(scrollPosition)
        }

        private func replaceSource(
            range: NSRange,
            with replacement: String,
            actionName: String
        ) {
            guard !replacement.contains("\u{FFFC}") else {
                NSSound.beep()
                return
            }
            let mutableSource = NSMutableString(string: text.wrappedValue)
            let safeRange = clamped(range, to: mutableSource.length)
            mutableSource.replaceCharacters(
                in: safeRange,
                with: replacement
            )
            apply(
                MarkdownEditResult(
                    text: mutableSource as String,
                    selection: NSRange(
                        location: safeRange.location
                            + (replacement as NSString).length,
                        length: 0
                    )
                ),
                actionName: actionName
            )
        }

        private func isInsideCodeBlock(_ sourceOffset: Int) -> Bool {
            model.spans.contains { span in
                guard case .codeBlock = span.style else {
                    return false
                }
                return sourceOffset >= span.sourceRange.location
                    && sourceOffset <= NSMaxRange(span.sourceRange)
            }
        }

        private func clamped(_ range: NSRange, to length: Int) -> NSRange {
            let location = min(max(0, range.location), length)
            return NSRange(
                location: location,
                length: min(max(0, range.length), length - location)
            )
        }
    }

    private struct CompositionState {
        let sourceText: String
        let sourceSelection: NSRange
        let renderedText: String
        let renderedRange: NSRange
        let model: MarkdownRenderModel
    }
}

@MainActor
private final class ReflowingTextScrollView: NSScrollView {
    var requestedDocumentWidth: CGFloat = 0 {
        didSet {
            guard abs(requestedDocumentWidth - oldValue) > 0.5 else {
                return
            }
            reflowDocument()
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        reflowDocument()
    }

    private func reflowDocument() {
        guard requestedDocumentWidth > 0,
            let textView = documentView as? NSTextView,
            let textContainer = textView.textContainer
        else {
            return
        }

        let currentContentWidth = contentSize.width
        let targetWidth = currentContentWidth > 1
            ? min(requestedDocumentWidth, currentContentWidth)
            : requestedDocumentWidth
        let targetContainerWidth = max(
            1,
            targetWidth - (textView.textContainerInset.width * 2)
        )
        let textViewNeedsResize = abs(
            textView.frame.width - targetWidth
        ) > 0.5
        let containerNeedsResize = abs(
            textContainer.containerSize.width - targetContainerWidth
        ) > 0.5
        guard textViewNeedsResize || containerNeedsResize else {
            return
        }

        if textViewNeedsResize {
            textView.setFrameSize(
                NSSize(width: targetWidth, height: textView.frame.height)
            )
        }
        if containerNeedsResize {
            textContainer.containerSize = NSSize(
                width: targetContainerWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textContainer.widthTracksTextView = true
        textView.layoutManager?.ensureLayout(for: textContainer)
    }
}
