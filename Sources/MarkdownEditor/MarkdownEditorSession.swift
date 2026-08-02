import AppKit
import MarkdownEditorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MarkdownEditorSession: ObservableObject {
    @Published private(set) var viewMode: EditorViewMode = .rich

    @Published var fileURL: URL? {
        didSet {
            fileExplorer.followDocument(fileURL)
        }
    }
    let fileExplorer: FileExplorerModel

    private let imageImporter: MarkdownImageImporter
    private weak var activeEditor: (any MarkdownEditingSurface)?
    private var rememberedSelection = NSRange(location: 0, length: 0)

    init(
        fileURL: URL?,
        imageImporter: MarkdownImageImporter = MarkdownImageImporter()
    ) {
        self.fileURL = fileURL
        fileExplorer = FileExplorerModel(documentURL: fileURL)
        self.imageImporter = imageImporter
    }

    func setViewMode(_ mode: EditorViewMode) {
        guard mode != viewMode else {
            return
        }
        if let activeEditor {
            activeEditor.commitPendingComposition()
            rememberedSelection = activeEditor.selectedSourceRange
        }
        viewMode = mode
    }

    func attach(_ editor: any MarkdownEditingSurface) {
        if let activeEditor,
            (activeEditor as AnyObject) === (editor as AnyObject)
        {
            return
        }
        activeEditor = editor
        editor.setSourceSelection(rememberedSelection)
    }

    func detach(_ editor: any MarkdownEditingSurface) {
        guard let activeEditor,
            (activeEditor as AnyObject) === (editor as AnyObject)
        else {
            return
        }
        rememberedSelection = editor.selectedSourceRange
        self.activeEditor = nil
    }

    func registerUndo(
        _ state: MarkdownEditResult,
        actionName: String,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: self) { session in
            guard let editor = session.activeEditor else {
                return
            }
            let inverseState = MarkdownEditResult(
                text: editor.sourceText,
                selection: editor.selectedSourceRange
            )
            editor.restore(state)
            guard let currentUndoManager = editor.hostingWindow?.undoManager else {
                return
            }
            session.registerUndo(
                inverseState,
                actionName: actionName,
                undoManager: currentUndoManager
            )
        }
        undoManager.setActionName(actionName)
    }

    func toggleInline(_ style: MarkdownInlineStyle) {
        applyFormatting("Format Text") { text, selection in
            MarkdownFormatting.toggleInline(
                style,
                in: text,
                selection: selection
            )
        }
    }

    func applyHeading(level: Int) {
        applyFormatting(level == 0 ? "Paragraph" : "Heading \(level)") {
            text,
            selection in
            MarkdownFormatting.applyHeading(
                level: level,
                in: text,
                selection: selection
            )
        }
    }

    func toggleList(_ style: MarkdownListStyle) {
        let actionName: String
        switch style {
        case .bulleted:
            actionName = "Bulleted List"
        case .numbered:
            actionName = "Numbered List"
        case .task:
            actionName = "Task List"
        }
        applyFormatting(actionName) { text, selection in
            MarkdownFormatting.toggleList(
                style,
                in: text,
                selection: selection
            )
        }
    }

    func toggleQuote() {
        applyFormatting("Quote") { text, selection in
            MarkdownFormatting.toggleQuote(
                in: text,
                selection: selection
            )
        }
    }

    func insertFencedCodeBlock() {
        applyFormatting("Fenced Code Block") { text, selection in
            MarkdownFormatting.wrapCodeBlock(
                in: text,
                selection: selection
            )
        }
    }

    func chooseExplorerFolder() {
        activeEditor?.commitPendingComposition()

        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.message = "Choose a folder to show in the file explorer."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = fileExplorer.rootURL

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard response == .OK, let folderURL = panel.url else {
                return
            }
            self?.fileExplorer.setUserSelectedRoot(folderURL)
        }

        if let window = activeEditor?.hostingWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func insertHorizontalRule() {
        applyFormatting("Horizontal Rule") { text, selection in
            MarkdownFormatting.insertHorizontalRule(
                in: text,
                selection: selection
            )
        }
    }

    func chooseLink() {
        guard activeEditor != nil else {
            present(error: MarkdownEditorPresentationError.editorUnavailable)
            return
        }
        activeEditor?.commitPendingComposition()

        let destinationField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 320, height: 24)
        )
        destinationField.placeholderString = "https://example.com"
        destinationField.stringValue = "https://"

        let alert = NSAlert()
        alert.messageText = "Insert Link"
        alert.informativeText = "Enter the destination for the selected text."
        alert.accessoryView = destinationField
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            let destination = destinationField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                return
            }
            self?.applyFormatting("Insert Link") { text, selection in
                MarkdownFormatting.insertLink(
                    destination: destination,
                    in: text,
                    selection: selection
                )
            }
        }

        if let window = activeEditor?.hostingWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func chooseAndInsertImage() {
        activeEditor?.commitPendingComposition()
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

        if let window = activeEditor?.hostingWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func insertAtSelection(_ text: String) {
        guard let activeEditor else {
            present(
                error: MarkdownEditorPresentationError.editorUnavailable
            )
            return
        }
        activeEditor.commitPendingComposition()

        let source = activeEditor.sourceText as NSString
        let selection = clamped(
            activeEditor.selectedSourceRange,
            to: source.length
        )
        let mutableSource = NSMutableString(string: source)
        mutableSource.replaceCharacters(in: selection, with: text)
        let insertionLength = (text as NSString).length
        activeEditor.apply(
            MarkdownEditResult(
                text: mutableSource as String,
                selection: NSRange(
                    location: selection.location + insertionLength,
                    length: 0
                )
            ),
            actionName: "Insert Image"
        )
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

    private func applyFormatting(
        _ actionName: String,
        transform: (String, NSRange) -> MarkdownEditResult
    ) {
        guard let activeEditor else {
            present(error: MarkdownEditorPresentationError.editorUnavailable)
            return
        }
        activeEditor.commitPendingComposition()
        let result = transform(
            activeEditor.sourceText,
            activeEditor.selectedSourceRange
        )
        activeEditor.apply(result, actionName: actionName)
        activeEditor.focus()
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        if let window = activeEditor?.hostingWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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

private enum MarkdownEditorPresentationError: Error, LocalizedError {
    case editorUnavailable

    var errorDescription: String? {
        "The requested edit could not be applied."
    }

    var recoverySuggestion: String? {
        "Click in the editor and try adding the image again."
    }
}
