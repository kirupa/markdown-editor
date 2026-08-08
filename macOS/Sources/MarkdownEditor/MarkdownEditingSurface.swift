import AppKit
import MarkdownEditorCore
import MarkdownEditorUI

@MainActor
protocol MarkdownEditingSurface: AnyObject {
    var sourceText: String { get }
    var selectedSourceRange: NSRange { get }
    var hostingWindow: NSWindow? { get }
    var hasFocus: Bool { get }
    var normalizedScrollPosition: CGFloat? { get }

    func apply(_ result: MarkdownEditResult, actionName: String)
    func restore(_ result: MarkdownEditResult)
    func commitPendingComposition()
    func setSourceSelection(_ selection: NSRange)
    func setSynchronizedSourceSelection(_ selection: NSRange)
    func setNormalizedScrollPosition(_ position: CGFloat)
    func focus()
}

@MainActor
final class EditorScrollSynchronizer: NSObject {
    /// Reports a settled scroll position. It is never called while the pane is
    /// being re-styled, so a half-laid-out position cannot escape to the
    /// other pane.
    var didScroll: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?
    private var isApplyingPosition = false

    /// The pane's current geometry, or `nil` if there is no pane.
    private var geometry: EditorScrollGeometry? {
        guard let scrollView else {
            return nil
        }
        return EditorScrollGeometry(
            documentHeight: scrollView.documentView?.frame.height ?? 0,
            viewportHeight: scrollView.contentView.bounds.height,
            offset: scrollView.contentView.bounds.minY
        )
    }

    /// Where this pane sits as a fraction of its travel, or `nil` when it has
    /// not been laid out well enough to say.
    ///
    /// A fraction is only meaningful against the document's true height, so
    /// this withholds an answer until the whole document has been laid out.
    /// `prepareLayout(toRestore:)` deliberately measures only part of it, and
    /// a fraction taken during that window describes the measured part rather
    /// than the document — a reader 5000pt into a 34000pt file looked 91% of
    /// the way through. AppKit finishes the layout in the background within a
    /// moment, so this starts answering again on its own.
    var normalizedPosition: CGFloat? {
        guard isLayoutComplete else {
            return nil
        }
        return geometry?.normalizedPosition
    }

    /// Whether every character has been laid out, so the document's reported
    /// height is its real one.
    private var isLayoutComplete: Bool {
        guard let textView = scrollView?.documentView as? NSTextView,
            let layoutManager = textView.layoutManager
        else {
            return false
        }
        let length = textView.textStorage?.length ?? 0
        return layoutManager.firstUnlaidCharacterIndex() >= length
    }

    /// The pane's exact scroll offset, used to put a pane back where it was
    /// after its text storage has been replaced. Restoring the offset itself
    /// rather than a fraction of the travel is what keeps the document still:
    /// a fraction moves the text whenever the document changes height.
    var documentOffset: CGFloat {
        scrollView?.contentView.bounds.minY ?? 0
    }

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView {
            return
        }
        detach()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    func detach() {
        if let contentView = scrollView?.contentView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
        }
        scrollView = nil
    }

    func setNormalizedPosition(_ position: CGFloat) {
        guard let scrollView else {
            return
        }

        withoutPublishingScroll {
            ensureFullLayout()
            scrollView.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()

            guard let geometry,
                let targetOffset = geometry.offset(
                    forNormalizedPosition: position
                ),
                geometry.shouldMove(to: targetOffset)
            else {
                return
            }
            scrollTo(targetOffset)
        }
    }

    /// Lays the whole document out so its reported height is its real one.
    ///
    /// The receiving side of a sync has to be as careful as the sending side.
    /// `normalizedPosition` withholds a fraction until this pane is fully
    /// measured; without the same care here a perfectly good fraction is
    /// turned into an offset against a half-measured height, which is the
    /// arithmetic this whole file exists to avoid. A pane that has just been
    /// created — entering Split, say — has laid out only the screenful it
    /// shows, so a document 136,000pt tall reports 600pt and a reader 80% of
    /// the way through lands at the very top.
    ///
    /// Unlike `prepareLayout(toRestore:)` this cannot be narrowed to the
    /// restored viewport: turning a fraction into an offset needs the *total*
    /// height, which is precisely what a partial layout does not know. The
    /// cost is real but paid once — AppKit keeps the result, so repeat calls
    /// measure at 0.00ms — and it is only reached when a pane is scrolled or
    /// joins a split, never on the typing path.
    private func ensureFullLayout() {
        guard let textView = scrollView?.documentView as? NSTextView,
            let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager
        else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
    }

    /// Lays out just enough of the document to put the viewport back at
    /// `offset`.
    ///
    /// A pane that has not been laid out yet reports a height covering only
    /// the part it has measured, and scrolling is clamped to that, so a reader
    /// restored partway down is dragged to the top: a 34057pt document reports
    /// the 600pt of its viewport, and an offset of 5000 lands at 0. That is
    /// the state `render` finds when a document is first opened into a pane.
    /// An already-measured pane is safe — AppKit keeps the frame height it has
    /// grown to and never shrinks it back — but the first render is not.
    ///
    /// Laying the whole document out fixes it and costs about 100ms per
    /// keystroke on an eight thousand line file, which is felt as typing lag.
    /// Only the part above the bottom of the restored viewport has to exist
    /// for the offset to survive the clamp, so that is all this measures. The
    /// cost is roughly 2ms and does not grow with the document.
    func prepareLayout(toRestore offset: CGFloat) {
        guard let scrollView,
            let textView = scrollView.documentView as? NSTextView,
            let textContainer = textView.textContainer,
            let layoutManager = textView.layoutManager
        else {
            return
        }
        let requiredHeight = offset
            + scrollView.contentView.bounds.height
            + Self.layoutMargin
        layoutManager.ensureLayout(
            forBoundingRect: NSRect(
                x: 0,
                y: 0,
                width: max(1, textContainer.size.width),
                height: max(1, requiredHeight)
            ),
            in: textContainer
        )
    }

    /// Puts the pane back at an exact offset, clamped to what the document can
    /// now show.
    func setDocumentOffset(_ offset: CGFloat) {
        guard let geometry else {
            return
        }
        let targetOffset = geometry.clampedOffset(offset)
        guard geometry.shouldMove(to: targetOffset) else {
            return
        }
        // Restoring the flag rather than clearing it matters: this is always
        // called from inside `withoutPublishingScroll`, and clearing it would
        // unsuppress the rest of the re-style.
        withoutPublishingScroll {
            scrollTo(targetOffset)
        }
    }

    /// Laid out a little beyond the restored viewport so the clamp has room
    /// and the first flick of the scroll wheel has something to show.
    private static let layoutMargin: CGFloat = 400

    func withoutPublishingScroll<Result>(
        _ action: () -> Result
    ) -> Result {
        let wasApplyingPosition = isApplyingPosition
        isApplyingPosition = true
        defer {
            isApplyingPosition = wasApplyingPosition
        }
        return action()
    }

    private func scrollTo(_ offset: CGFloat) {
        guard let scrollView else {
            return
        }
        let clipView = scrollView.contentView
        clipView.scroll(
            to: NSPoint(x: clipView.bounds.minX, y: offset)
        )
        scrollView.reflectScrolledClipView(clipView)
    }

    @objc
    private func boundsDidChange(_ notification: Notification) {
        guard !isApplyingPosition else {
            return
        }
        // A pane that is mid-relayout has no meaningful position to report,
        // and reporting one moves the other pane to a place the reader never
        // asked for.
        guard let position = normalizedPosition else {
            return
        }
        didScroll?(position)
    }
}

/// Whether a selection is fully on screen.
///
/// Used to decide whether a re-style has to chase the caret. Revealing a caret
/// that is already in view moves the page for no reason, which is half of what
/// a writer sees as the document jumping.
///
/// Containment rather than overlap is the test, because a line straddling the
/// top or bottom edge overlaps the viewport while being all but unreadable,
/// and typing on it would never correct itself. A selection taller than the
/// viewport can never be contained, so that case falls back to overlap.
@MainActor
func isSelectionVisible(_ range: NSRange, in textView: NSTextView) -> Bool {
    guard let layoutManager = textView.layoutManager,
        let textContainer = textView.textContainer
    else {
        return false
    }
    let glyphRange = layoutManager.glyphRange(
        forCharacterRange: range,
        actualCharacterRange: nil
    )
    var selectionRect = layoutManager.boundingRect(
        forGlyphRange: glyphRange,
        in: textContainer
    )
    let origin = textView.textContainerOrigin
    selectionRect.origin.x += origin.x
    selectionRect.origin.y += origin.y
    // An insertion point is an empty rectangle. Give it the size of the
    // character it sits against so it can be compared with the viewport.
    if selectionRect.height <= 0 {
        selectionRect.size.height = textView.font?.boundingRectForFont.height
            ?? 16
    }
    if selectionRect.width <= 0 {
        selectionRect.size.width = 1
    }

    let visibleRect = textView.visibleRect
    if selectionRect.height >= visibleRect.height {
        return visibleRect.intersects(selectionRect)
    }
    return visibleRect.contains(selectionRect)
}
