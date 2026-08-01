import AppKit
import MarkdownEditorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MarkdownEditorSession: ObservableObject {
    var fileURL: URL?
    weak var textView: NSTextView?

    private let imageImporter: MarkdownImageImporter

    init(
        fileURL: URL?,
        imageImporter: MarkdownImageImporter = MarkdownImageImporter()
    ) {
        self.fileURL = fileURL
        self.imageImporter = imageImporter
    }

    func chooseAndInsertImage() {
        guard fileURL != nil else {
            present(error: MarkdownImageImportError.documentHasNoFileLocation)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Add Image"
        panel.message = """
            The image will be copied into an assets folder beside the Markdown \
            document.
            """
        panel.prompt = "Add Image"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = MarkdownImageImporter
            .supportedFilenameExtensions
            .sorted()
            .compactMap { UTType(filenameExtension: $0) }

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard response == .OK, let sourceURL = panel.url else {
                return
            }
            self?.importAndInsertImage(at: sourceURL)
        }

        if let window = textView?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func insertAtSelection(_ text: String) {
        guard let textView else {
            present(
                error: MarkdownEditorPresentationError.editorUnavailable
            )
            return
        }

        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    private func importAndInsertImage(at sourceURL: URL) {
        do {
            let importedImage = try imageImporter.importImage(
                at: sourceURL,
                forDocumentAt: fileURL
            )
            insertAtSelection(importedImage.markdownReference)
        } catch {
            present(error: error)
        }
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        if let window = textView?.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private enum MarkdownEditorPresentationError: Error, LocalizedError {
    case editorUnavailable

    var errorDescription: String? {
        "The image reference could not be inserted."
    }

    var recoverySuggestion: String? {
        "Click in the editor and try adding the image again."
    }
}
