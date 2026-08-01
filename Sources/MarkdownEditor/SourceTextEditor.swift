import AppKit
import SwiftUI

struct SourceTextEditor: NSViewRepresentable {
    @Binding var text: String
    let session: MarkdownEditorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            preconditionFailure("NSTextView.scrollableTextView() returned no text view")
        }

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

        session.textView = textView
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

        if session.textView !== textView {
            session.textView = textView
        }
    }

    static func dismantleNSView(
        _ scrollView: NSScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView as? NSTextView else {
            return
        }
        textView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text.wrappedValue = textView.string
        }
    }
}
