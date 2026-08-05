import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI
import UIKit

/// The rendered pane, which is also editable.
///
/// What is on screen is the *rendered* text — no `#`, no `**` — but typing in
/// it edits the Markdown. The trick, and it is the same one the Mac and web
/// builds use, is that `MarkdownRenderModel` records where every rendered
/// range came from in the source. An edit is turned back into a source edit by
/// diffing the surface text and mapping the changed range through that model,
/// so Markdown the renderer does not show is still preserved untouched.
struct MarkdownRichTextEditor: UIViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    let documentURL: URL?
    let theme: EditorColorTheme

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(
            top: 16, left: 12, bottom: 24, right: 12
        )
        context.coordinator.textView = textView
        context.coordinator.render(text, theme: theme, documentURL: documentURL)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfNeeded(
            text: text,
            revision: controller.externalRevision,
            theme: theme,
            documentURL: documentURL
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownRichTextEditor
        weak var textView: UITextView?

        private var model = MarkdownRenderer.render("")
        private var appliedRevision = -1
        private var appliedTheme: EditorColorTheme?
        private var appliedText: String?
        private var isApplyingProgrammatically = false

        init(parent: MarkdownRichTextEditor) {
            self.parent = parent
        }

        func render(
            _ source: String,
            theme: EditorColorTheme,
            documentURL: URL?
        ) {
            guard let textView else { return }
            isApplyingProgrammatically = true
            defer { isApplyingProgrammatically = false }

            model = MarkdownRenderer.render(source)
            let selected = textView.selectedRange
            textView.attributedText = RichMarkdownStyler.attributedString(
                for: model,
                documentURL: documentURL,
                colorTheme: theme
            )
            textView.backgroundColor = theme.editorBackgroundColor
            textView.tintColor = theme.accentColor
            textView.typingAttributes = MarkdownSourceStyler.baseAttributes(
                colorTheme: theme
            )
            let length = (textView.text ?? "" as String).utf16.count
            textView.selectedRange = NSRange(
                location: min(selected.location, length), length: 0
            )
            appliedText = source
            appliedTheme = theme
        }

        func syncIfNeeded(
            text: String,
            revision: Int,
            theme: EditorColorTheme,
            documentURL: URL?
        ) {
            let themeChanged = appliedTheme != theme
            let textChanged = appliedText != text
            let cameFromElsewhere = revision != appliedRevision
                && parent.controller.lastEditingSurface != .rich

            if themeChanged || (textChanged && cameFromElsewhere) {
                render(text, theme: theme, documentURL: documentURL)
            } else if textChanged {
                appliedText = text
            }
            appliedRevision = revision
        }

        /// Turns an edit to the rendered text into an edit to the source.
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard !isApplyingProgrammatically else { return true }

            let sourceRange = model.sourceRange(for: range)
            let source = parent.text as NSString
            let clamped = NSRange(
                location: min(sourceRange.location, source.length),
                length: min(
                    sourceRange.length,
                    max(0, source.length - min(sourceRange.location, source.length))
                )
            )
            let updated = source.replacingCharacters(
                in: clamped, with: replacement
            )

            // Where the caret should end up, expressed in the *rendered* text,
            // which is what the user is looking at.
            let renderedCaret = range.location + (replacement as NSString).length

            parent.text = updated
            parent.controller.recordEdit(from: .rich)
            render(
                updated,
                theme: parent.theme,
                documentURL: parent.documentURL
            )
            appliedRevision = parent.controller.externalRevision

            let length = (textView.text ?? "").utf16.count
            let caret = NSRange(
                location: min(max(0, renderedCaret), length), length: 0
            )
            textView.selectedRange = caret
            parent.controller.selection = model.sourceRange(for: caret)
            return false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingProgrammatically else { return }
            parent.controller.selection = model.sourceRange(
                for: textView.selectedRange
            )
        }
    }
}
