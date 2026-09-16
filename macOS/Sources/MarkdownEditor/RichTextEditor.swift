import AppKit
import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

struct RichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let documentURL: URL?
    let session: MarkdownEditorSession
    let colorTheme: EditorColorTheme
    let layoutWidth: CGFloat
    /// The column prose is set in, and how far a picture may reach past it.
    let page: MarkdownPageMetrics
    /// The critique whose passages are shaded in this pane, if any.
    @ObservedObject var critique: CritiqueModel

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            documentURL: documentURL,
            session: session,
            colorTheme: colorTheme,
            page: page
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

        textView.didClickCritiqueHighlight = { [weak coordinator = context.coordinator] id in
            coordinator?.critique?.selectedFindingID = id
        }
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
        textView.textContainerInset = NSSize(
            width: 24, height: Layout.textTopInset
        )
        textView.setAccessibilityLabel("Rendered Markdown editor")
        scrollView.requestedDocumentWidth = layoutWidth
        textView.page = page
        colorTheme.apply(to: textView, in: scrollView)

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
        textView.naturalSizeForImage = { [weak session] attachment in
            session?.naturalSize(ofRenderedImage: attachment)
        }
        textView.commitImageSize = {
            [weak session, weak coordinator = context.coordinator] size, range in
            guard let session else { return }
            guard let coordinator else {
                session.resizeImageAtSelection(to: size)
                return
            }
            // Name the pane and the offset the handles were actually drawn
            // around. Resolving it again by focus can land on the other pane.
            session.resizeImage(
                in: coordinator,
                atSourceLocation: coordinator.sourceLocation(forRendered: range),
                to: size
            )
        }
        textView.moveImage = {
            [weak session, weak coordinator = context.coordinator] range, destination in
            guard let session, let coordinator else { return }
            session.moveImage(
                in: coordinator,
                fromSourceLocation: coordinator.sourceLocation(forRendered: range),
                toSourceLocation: coordinator.sourceLocation(
                    forRendered: NSRange(location: destination, length: 0)
                )
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
        let themeChanged = context.coordinator.colorTheme != colorTheme
        if themeChanged {
            (textView as? RichMarkdownTextView)?
                .finishPendingComposition()
        }
        colorTheme.apply(to: textView, in: scrollView)
        (textView as? RichMarkdownTextView)?.page = page
        context.coordinator.applyCritique(critique)
        context.coordinator.update(
            text: $text,
            documentURL: documentURL,
            colorTheme: colorTheme,
            page: page
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
        var colorTheme: EditorColorTheme
        var page: MarkdownPageMetrics

        /// The document, kept up to date one block at a time. Nothing on the
        /// typing path ever asks it for the whole document.
        private let renderer = MarkdownIncrementalRenderer()
        private var renderedSource = ""
        /// What the last edit actually changed, when the caller knew. Without
        /// it a whole new document has to be compared against the old one to
        /// find the difference, which is cheap but not free.
        private var pendingSourceEdit: MarkdownTextReplacement?
        /// How far the text storage has run ahead of the render model, which
        /// happens only while an input method has marked text on screen. See
        /// `spliceRange(for:drift:)`.
        private var pendingStorageDrift: (range: NSRange, delta: Int)?
        private var renderedDocumentURL: URL?
        private var renderedColorTheme: EditorColorTheme?
        private var renderedPage: MarkdownPageMetrics?
        weak var critique: CritiqueModel?
        private var shownHighlights: [RichMarkdownTextView.CritiqueHighlight] = []
        private var scrolledToFinding: UUID?
        private var isRendering = false
        private var compositionState: CompositionState?
        private let scrollSynchronizer = EditorScrollSynchronizer()

        init(
            text: Binding<String>,
            documentURL: URL?,
            session: MarkdownEditorSession,
            colorTheme: EditorColorTheme,
            page: MarkdownPageMetrics
        ) {
            self.text = text
            self.documentURL = documentURL
            self.session = session
            self.colorTheme = colorTheme
            self.page = page
            super.init()
            observeRemoteImages()
        }

        /// An image referenced by web address is not on disk when the document
        /// is first styled, so the reference draws as a placeholder. When the
        /// bytes arrive the document is styled again and the picture appears in
        /// place. Without this the editor would show the placeholder until the
        /// next keystroke happened to redraw it.
        // The selector form is used rather than the block form so the
        // observation is a zeroing weak reference the notification centre drops
        // by itself. A token would have to be removed in `deinit`, which under
        // Swift 6 cannot touch a main-actor property.
        private func observeRemoteImages() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(remoteImageDidLoad),
                name: RemoteImageStore.didLoadImage,
                object: nil
            )
        }

        @objc private func remoteImageDidLoad() {
            guard textView != nil, !isRendering else { return }
            // Settle any marked text first. Re-styling underneath an IME would
            // move the ground out from under the composition, and the commit
            // maps its difference through the document as it was when the
            // composition began.
            commitPendingComposition()
            // Re-styling replaces the text storage, so the caret has to be put
            // back exactly where it was, and the view must not scroll: the
            // image may be far from what the writer is looking at.
            render(
                sourceSelection: selectedSourceRange,
                scrollToSelection: false
            )
        }

        var sourceText: String {
            text.wrappedValue
        }

        /// Where a rendered range starts in the Markdown source.
        func sourceLocation(forRendered range: NSRange) -> Int {
            renderer.sourceRange(for: range).location
        }

        var selectedSourceRange: NSRange {
            guard let textView else {
                return NSRange(location: 0, length: 0)
            }
            return renderer.sourceRange(for: textView.selectedRange())
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

        var normalizedScrollPosition: CGFloat? {
            scrollSynchronizer.normalizedPosition
        }

        func observeScrolling(in scrollView: NSScrollView) {
            // Attached, but reporting nowhere: there is one pane, so there
            // is no neighbour to move. The synchroniser is still what
            // measures and restores a scroll position across a re-render,
            // which is the "never jump" contract in `check-scroll`.
            scrollSynchronizer.attach(to: scrollView)
        }

        func stopObservingScrolling() {
            scrollSynchronizer.didScroll = nil
            scrollSynchronizer.detach()
        }

        func update(
            text: Binding<String>,
            documentURL: URL?,
            colorTheme: EditorColorTheme,
            page: MarkdownPageMetrics
        ) {
            self.text = text
            self.documentURL = documentURL
            self.colorTheme = colorTheme
            self.page = page
            let contentChanged = renderedSource != text.wrappedValue
            let documentChanged = renderedDocumentURL != documentURL
            let themeChanged = renderedColorTheme != colorTheme
            // The indents that hold prose to the column are baked into the
            // attributed text, so a change of column has to be re-styled and
            // not merely re-laid-out.
            let pageChanged = renderedPage != page
            guard contentChanged || documentChanged || themeChanged
                || pageChanged
            else {
                return
            }

            let fallbackSelection = selectedSourceRange
            let selection = session?.selectionForEditorUpdate(
                fallback: fallbackSelection
            ) ?? fallbackSelection
            // A palette, a column width, or a different file changes how every
            // character is drawn, so those are the occasions — and the only
            // ones — that still re-style the whole document. A change of text
            // is a change to the blocks the text changed in.
            render(
                sourceSelection: selection,
                // Never chases the caret on a content change. That
                // followed the *other* pane's caret when two were tracking
                // each other; with one pane the caret is already where the
                // writer put it, and scrolling to it fights them.
                scrollToSelection: false,
                wholeDocument: documentChanged || themeChanged || pageChanged
            )
        }

        /// Shade the passages the critique points at, and follow its selection.
        ///
        /// The conversion from source offsets to rendered ones has to happen
        /// here: a critique is written about the Markdown the author saved,
        /// while this pane shows text with the markup taken out, so the two
        /// disagree by however much syntax came before the passage.
        func applyCritique(_ critique: CritiqueModel) {
            self.critique = critique
            guard let textView = textView as? RichMarkdownTextView else { return }

            let highlights = critique.highlights.compactMap {
                id, sourceRange, severity -> RichMarkdownTextView.CritiqueHighlight? in
                let rendered = renderer.renderedRange(for: sourceRange)
                guard rendered.length > 0 else { return nil }
                let selected = critique.selectedFindingID == id
                return RichMarkdownTextView.CritiqueHighlight(
                    id: id,
                    range: rendered,
                    colour: selected
                        ? severity.selectedHighlight(on: colorTheme.mode)
                        : severity.highlight(on: colorTheme.mode)
                )
            }
            if highlights != shownHighlights {
                shownHighlights = highlights
                textView.critiqueHighlights = highlights
            }

            // Bring the passage into view when a card is opened, but only once
            // per selection: doing it on every update would fight the author
            // for the scroll position while they read.
            guard critique.selectedFindingID != scrolledToFinding else { return }
            scrolledToFinding = critique.selectedFindingID
            guard
                let id = critique.selectedFindingID,
                let item = critique.item(withID: id),
                let sourceRange = item.range
            else {
                return
            }
            let rendered = renderer.renderedRange(for: sourceRange)
            guard rendered.length > 0 else { return }
            textView.scrollRangeToVisible(rendered)
        }

        func apply(_ result: MarkdownEditResult, actionName: String) {
            apply(result, actionName: actionName, edit: nil)
        }

        private func apply(
            _ result: MarkdownEditResult,
            actionName: String,
            edit: MarkdownTextReplacement?
        ) {
            let previousState = MarkdownEditResult(
                text: text.wrappedValue,
                selection: selectedSourceRange
            )
            set(result, edit: edit)
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
            setSourceSelection(
                selection,
                scrollToSelection: true,
                publishesScroll: true
            )
        }

        func setSynchronizedSourceSelection(_ selection: NSRange) {
            setSourceSelection(
                selection,
                scrollToSelection: true,
                publishesScroll: false
            )
        }

        func setNormalizedScrollPosition(_ position: CGFloat) {
            scrollSynchronizer.setNormalizedPosition(position)
        }

        private func setSourceSelection(
            _ selection: NSRange,
            scrollToSelection: Bool,
            publishesScroll: Bool = true
        ) {
            guard let textView else {
                return
            }
            let renderedSelection = clamped(
                renderer.renderedRange(for: selection),
                to: textView.textStorage?.length ?? 0
            )
            textView.setSelectedRange(renderedSelection)
            guard scrollToSelection else {
                return
            }
            // Only chase the caret when it has actually gone out of sight.
            // Revealing a caret that is already on screen is what produced
            // the second half of the jump, snapping the page back after the
            // re-style had already moved it.
            guard !isSelectionVisible(renderedSelection, in: textView) else {
                return
            }
            let revealSelection = {
                textView.scrollRangeToVisible(renderedSelection)
            }
            if publishesScroll {
                revealSelection()
            } else {
                scrollSynchronizer.withoutPublishingScroll(revealSelection)
            }
        }

        func focus() {
            guard let textView else {
                return
            }
            textView.window?.makeFirstResponder(textView)
        }

        /// Re-styles what an edit changed, and nothing else.
        ///
        /// The whole document is only ever rebuilt for something that changes
        /// how every character is drawn — a palette, a column width, a
        /// different file. An edit re-styles the blocks it landed in and
        /// splices them into the text storage, which leaves every glyph
        /// outside them laid out and every measurement TextKit has already
        /// made intact. That is what keeps the pane still as well as quick:
        /// nothing is thrown away, so there is nothing to put back.
        ///
        /// The whole-document path still has to hold the pane still across the
        /// replacement, which is what the three steps below are for: nothing
        /// is published while the pane is in pieces, layout is forced before
        /// anything asks how tall the document is, and the pane is put back at
        /// the exact offset it was at rather than at a fraction of a height
        /// that has changed underneath it.
        func render(
            sourceSelection: NSRange,
            scrollToSelection: Bool = true,
            wholeDocument: Bool = true
        ) {
            guard let textView, let textStorage = textView.textStorage else {
                return
            }

            isRendering = true
            let restoredOffset = scrollSynchronizer.documentOffset
            // A splice lands at an offset in the text storage, so the storage
            // and the model have to be describing the same text for it to land
            // in the right place. The one thing that puts them out of step is
            // an input method writing marked text into the view without asking
            // — `drift` says how much of that is outstanding. Checking is a
            // comparison of two integers, and being wrong about it would write
            // a block into the middle of a sentence, so anything unexpected
            // falls back to rebuilding the document.
            let drift = pendingStorageDrift
            pendingStorageDrift = nil
            let isSpliceable = !wholeDocument
                && textStorage.length
                    == renderer.renderedLength + (drift?.delta ?? 0)
            scrollSynchronizer.withoutPublishingScroll {
                if !isSpliceable {
                    renderer.reset(source: text.wrappedValue)
                    let update = MarkdownRenderUpdate(
                        renderedRange: NSRange(location: 0, length: 0),
                        fragment: renderer.renderedText(),
                        spans: renderer.allSpans(),
                        reparsedBlockCount: renderer.blockCount
                    )
                    textStorage.setAttributedString(styled(update))
                    // Measure enough of the new document to put the reader
                    // back where they were. Without this the pane reports only
                    // the height it has measured so far and the restore is
                    // clamped towards the top.
                    scrollSynchronizer.prepareLayout(toRestore: restoredOffset)
                    scrollSynchronizer.setDocumentOffset(restoredOffset)
                } else {
                    let edit = pendingSourceEdit
                    let update = edit.map {
                        renderer.replace(
                            sourceRange: $0.range,
                            with: $0.replacement
                        )
                    } ?? renderer.update(source: text.wrappedValue)
                    if let target = spliceRange(
                        for: update.renderedRange,
                        drift: drift
                    ) {
                        textStorage.beginEditing()
                        textStorage.replaceCharacters(
                            in: target,
                            with: styled(update)
                        )
                        textStorage.endEditing()
                    } else {
                        textStorage.setAttributedString(
                            styled(
                                MarkdownRenderUpdate(
                                    renderedRange: NSRange(
                                        location: 0,
                                        length: 0
                                    ),
                                    fragment: renderer.renderedText(),
                                    spans: renderer.allSpans(),
                                    reparsedBlockCount: renderer.blockCount
                                )
                            )
                        )
                        scrollSynchronizer.prepareLayout(
                            toRestore: restoredOffset
                        )
                        scrollSynchronizer.setDocumentOffset(restoredOffset)
                    }
                }
                pendingSourceEdit = nil

                renderedSource = text.wrappedValue
                renderedDocumentURL = documentURL
                renderedColorTheme = colorTheme
                renderedPage = page
                setSourceSelection(
                    sourceSelection,
                    scrollToSelection: scrollToSelection,
                    publishesScroll: false
                )
            }
            isRendering = false
            // The handles and the image cursor rects are measured from the
            // layout, and a splice invalidates the layout around it, so both
            // are stale until they are measured again.
            (textView as? RichMarkdownTextView)?.updateImageHandles()
            // Temporary attributes live on the layout manager, and replacing
            // the storage takes them with it. Without this every critique
            // highlight disappears on the next keystroke.
            (textView as? RichMarkdownTextView)?.redrawCritiqueHighlights()
            // The selection changes AppKit made while the storage was being
            // replaced were suppressed as intermediate. Publish the settled
            // one now, so the two panes still track each other's caret and
            // the session's remembered selection is the real one.
            if hasFocus {
                session?.noteSelection(selectedSourceRange)
            }
        }

        /// Where a re-rendered block goes in the text storage.
        ///
        /// The renderer answers in the coordinates of the document it knows
        /// about, which is the one before any marked text was typed into the
        /// view. A block that encloses that marked text is that much longer on
        /// screen than the renderer thinks, and this is where that is added
        /// back. A block that does not enclose it has not moved at all, since
        /// the composition is always inside the block being replaced.
        /// Returns nil when the two cannot be reconciled, which means the
        /// document has to be rebuilt rather than spliced.
        private func spliceRange(
            for renderedRange: NSRange,
            drift: (range: NSRange, delta: Int)?
        ) -> NSRange? {
            guard let drift, drift.delta != 0 else {
                return renderedRange
            }
            guard renderedRange.location <= drift.range.location,
                NSMaxRange(renderedRange) >= NSMaxRange(drift.range)
            else {
                return nil
            }
            return NSRange(
                location: renderedRange.location,
                length: renderedRange.length + drift.delta
            )
        }

        private func styled(_ update: MarkdownRenderUpdate) -> NSAttributedString {
            RichMarkdownStyler.attributedString(
                forFragment: update.fragment,
                spans: update.spans,
                documentURL: documentURL,
                colorTheme: colorTheme,
                page: page
            )
        }

        func textDidBeginEditing(_ notification: Notification) {
            session?.activate(self)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Replacing the text storage makes AppKit move the selection
            // before the intended one is put back, and that intermediate
            // value is not the writer moving the caret. Publishing it sent
            // the other pane thousands of characters away and straight back
            // on every keystroke, which is the jumping this guard removes.
            // `render` publishes the settled selection once it is done.
            guard !isRendering else {
                return
            }
            if hasFocus {
                session?.activate(self)
                session?.noteSelection(selectedSourceRange)
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

            let sourceRange = renderer.sourceRange(
                for: clamped(
                    affectedCharRange,
                    to: textView.textStorage?.length ?? 0
                )
            )
            let replacement = replacementString
            if replacement == "\n" {
                if renderer.isInsideCodeBlock(sourceOffset: sourceRange.location) {
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
                sourceSelection: renderer.sourceRange(for: safeRenderedRange),
                renderedText: textView.string,
                renderedRange: safeRenderedRange
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
            // The renderer still holds the document as it was when the
            // composition began: nothing re-renders while marked text is on
            // screen, and everything that would — a theme change, a picture
            // arriving — commits the composition first.
            let composedSource = compositionState.sourceText as NSString
            let sourceRange = clamped(
                renderer.sourceRange(for: difference.range),
                to: composedSource.length
            )
            let result = MarkdownEditResult(
                text: composedSource.replacingCharacters(
                    in: sourceRange,
                    with: difference.replacement
                ),
                selection: NSRange(
                    location: sourceRange.location
                        + (difference.replacement as NSString).length,
                    length: 0
                )
            )
            pendingStorageDrift = (
                range: difference.range,
                delta: (difference.replacement as NSString).length
                    - difference.range.length
            )
            set(
                result,
                edit: MarkdownTextReplacement(
                    range: sourceRange,
                    replacement: difference.replacement
                )
            )
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
                renderer.sourceRange(for: range, includingMarkup: true),
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

        /// Applies a new version of the document.
        ///
        /// `edit` is what the caller changed, when the caller knew — typing
        /// always does. Without it the renderer has to find the difference by
        /// comparing the two documents, which is right but costs a pass over
        /// both; a keystroke should never pay that.
        private func set(
            _ state: MarkdownEditResult,
            edit: MarkdownTextReplacement? = nil
        ) {
            pendingSourceEdit = edit
            text.wrappedValue = state.text
            // The caret has been moved on purpose here, so following it is
            // wanted. `render` only chases the caret when the edit has taken
            // it off screen.
            render(
                sourceSelection: state.selection,
                scrollToSelection: true,
                wholeDocument: false
            )
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
            let source = text.wrappedValue as NSString
            let safeRange = clamped(range, to: source.length)
            let edit = MarkdownTextReplacement(
                range: safeRange,
                replacement: replacement
            )
            apply(
                MarkdownEditResult(
                    text: source.replacingCharacters(
                        in: safeRange,
                        with: replacement
                    ),
                    selection: NSRange(
                        location: safeRange.location
                            + (replacement as NSString).length,
                        length: 0
                    )
                ),
                actionName: actionName,
                edit: edit
            )
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
