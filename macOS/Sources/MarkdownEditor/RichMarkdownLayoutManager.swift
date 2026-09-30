import AppKit

/// The rendered editor's layout manager: AppKit's own, except that it leaves
/// the selection to the text view.
///
/// AppKit paints a selection as a hard-edged band per line, and while the
/// window is in the background it paints it in the system's grey whatever the
/// text view asks for. `RichMarkdownTextView` draws the selection itself —
/// rounded, fitted to the words, fading where it carries on to the next line
/// — so the band has to go in both states, and this is the one place both are
/// painted.
final class RichMarkdownLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(
        _ rectArray: UnsafePointer<NSRect>,
        count rectCount: Int,
        forCharacterRange charRange: NSRange,
        color: NSColor
    ) {
        // Text is only ever drawn on the main thread, where the view lives.
        let textView = firstTextView as? RichMarkdownTextView
        let isBand = MainActor.assumeIsolated {
            textView?.isSelectionBandFill(
                characterRange: charRange,
                color: color
            ) ?? false
        }
        if isBand { return }
        super.fillBackgroundRectArray(
            rectArray,
            count: rectCount,
            forCharacterRange: charRange,
            color: color
        )
    }
}
