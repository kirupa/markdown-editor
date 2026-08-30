import AppKit
import MarkdownEditorUI

/// The parts of theming that are genuinely AppKit.
///
/// The palette itself is shared with iOS in `MarkdownEditorUI`; applying it to
/// an `NSTextView`, an `NSOutlineView`, and their scroll views is not
/// shareable, because UIKit has neither of those classes nor the notion of an
/// `NSAppearance`. Splitting it here keeps the shared module free of `#if
/// os(macOS)` blocks.
extension EditorColorTheme {
    var appKitAppearance: NSAppearance? {
        NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
    }

    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        textView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        textView.drawsBackground = true
        textView.backgroundColor = editorBackgroundColor
        textView.textColor = primaryTextColor
        textView.insertionPointColor = primaryTextColor
        let selection: [NSAttributedString.Key: Any] = [
            .backgroundColor: selectionBackgroundColor,
            .foregroundColor: selectionTextColor
        ]
        // The rendered view hides the band while a picture is selected, so it
        // owns the decision; setting it here directly would undo that.
        if let rich = textView as? RichMarkdownTextView {
            rich.baseSelectedTextAttributes = selection
        } else {
            textView.selectedTextAttributes = selection
        }
        scrollView.drawsBackground = true
        scrollView.backgroundColor = editorBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = editorBackgroundColor
    }

    @MainActor
    func apply(
        to outlineView: NSOutlineView,
        in scrollView: NSScrollView
    ) {
        outlineView.appearance = appKitAppearance
        scrollView.appearance = appKitAppearance
        outlineView.backgroundColor = sidebarBackgroundColor
        scrollView.drawsBackground = true
        scrollView.backgroundColor = sidebarBackgroundColor
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = sidebarBackgroundColor
    }
}
