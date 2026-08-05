import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI
import UIKit

/// The raw Markdown pane.
///
/// Every character of the source is present and editable; the styling only
/// changes how it looks. That rule, and the code that enforces it, is
/// `MarkdownSourceStyler` in the shared package — the same one macOS uses.
struct MarkdownSourceTextEditor: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    let theme: EditorColorTheme

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        // Smart quotes and dashes rewrite what was typed. In a file whose
        // whole point is that its characters are meaningful, they must be off.
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContainerInset = UIEdgeInsets(
            top: 16, left: 12, bottom: 24, right: 12
        )
        context.coordinator.textView = textView
        context.coordinator.applySource(text, theme: theme)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded(
            text: text,
            revision: controller.externalRevision,
            selection: controller.selection,
            theme: theme
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownSourceTextEditor
        weak var textView: UITextView?

        private var appliedRevision = -1
        private var appliedTheme: EditorColorTheme?
        private var appliedText: String?
        private var isApplyingProgrammatically = false

        init(parent: MarkdownSourceTextEditor) {
            self.parent = parent
        }

        func applySource(_ source: String, theme: EditorColorTheme) {
            guard let textView else { return }
            isApplyingProgrammatically = true
            defer { isApplyingProgrammatically = false }

            let selected = textView.selectedRange
            MarkdownSourceStyler.apply(source, to: textView, colorTheme: theme)
            textView.backgroundColor = theme.editorBackgroundColor
            textView.tintColor = theme.accentColor
            textView.selectedRange = NSRange(
                location: min(selected.location, (source as NSString).length),
                length: 0
            )
            appliedText = source
            appliedTheme = theme
        }

        func syncIfNeeded(
            text: String,
            revision: Int,
            selection: NSRange,
            theme: EditorColorTheme
        ) {
            guard let textView else { return }
            let themeChanged = appliedTheme != theme
            let textChanged = appliedText != text

            // Restyling on every keystroke would fight the caret and the undo
            // stack, so it only happens when the text arrived from elsewhere.
            let cameFromElsewhere = revision != appliedRevision
                && parent.controller.lastEditingSurface != .source

            if themeChanged || (textChanged && cameFromElsewhere) {
                applySource(text, theme: theme)
                if cameFromElsewhere {
                    let length = (text as NSString).length
                    textView.selectedRange = NSRange(
                        location: min(max(0, selection.location), length),
                        length: min(
                            selection.length,
                            max(0, length - min(selection.location, length))
                        )
                    )
                }
            } else if textChanged, !cameFromElsewhere {
                appliedText = text
            }
            appliedRevision = revision
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammatically else { return }
            let updated = textView.text ?? ""
            appliedText = updated
            parent.text = updated
            parent.controller.selection = textView.selectedRange
            parent.controller.recordEdit(from: .source)

            // Restyle only the paragraph that changed, so long documents stay
            // responsive and the caret is not disturbed.
            restyleCurrentParagraph(in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammatically else { return }
            parent.controller.selection = textView.selectedRange
        }

        private func restyleCurrentParagraph(in textView: UITextView) {
            let source = textView.text ?? ""
            let selected = textView.selectedRange
            isApplyingProgrammatically = true
            defer { isApplyingProgrammatically = false }
            MarkdownSourceStyler.apply(
                source, to: textView, colorTheme: parent.theme
            )
            textView.selectedRange = selected
        }
    }
}
