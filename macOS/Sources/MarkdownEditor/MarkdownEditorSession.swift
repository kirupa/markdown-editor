import AppKit
import MarkdownEditorCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MarkdownEditorSession: ObservableObject {
    @Published private(set) var viewMode: EditorViewMode = .split

    @Published var fileURL: URL? {
        didSet {
            fileExplorer.followDocument(fileURL)
        }
    }
    let fileExplorer: FileExplorerModel

    private let imageImporter: MarkdownImageImporter
    private weak var activeEditor: (any MarkdownEditingSurface)?
    private var attachedEditors: [WeakEditingSurface] = []
    private var rememberedSelection: NSRange
    private var isSynchronizingScroll = false
    private var isSynchronizingSelection = false

    init(
        fileURL: URL?,
        initialText: String = "",
        imageImporter: MarkdownImageImporter = MarkdownImageImporter()
    ) {
        self.fileURL = fileURL
        fileExplorer = FileExplorerModel(documentURL: fileURL)
        self.imageImporter = imageImporter
        // The first editor to attach is given this, so a new document opens
        // with the caret inside its heading rather than in front of the `#`.
        rememberedSelection = NewMarkdownDocument.initialSelection(
            text: initialText,
            isNewDocument: fileURL == nil
        )
    }

    func setViewMode(_ mode: EditorViewMode) {
        guard mode != viewMode else {
            return
        }
        if let editor = currentEditor() {
            editor.commitPendingComposition()
            rememberedSelection = editor.selectedSourceRange
        }
        viewMode = mode
    }

    func cycleViewMode() {
        switch viewMode {
        case .rich:
            setViewMode(.source)
        case .source:
            setViewMode(.split)
        case .split:
            setViewMode(.rich)
        }
    }

    func attach(_ editor: any MarkdownEditingSurface) {
        let editors = liveEditors()
        if !editors.contains(where: { sameEditor($0, editor) }) {
            attachedEditors.append(WeakEditingSurface(editor))
        }

        if activeEditor == nil {
            activeEditor = editor
            editor.setSourceSelection(rememberedSelection)
        } else if editor.hasFocus {
            activeEditor = editor
        }

        if viewMode == .split,
            let activeEditor,
            !sameEditor(activeEditor, editor)
        {
            editor.setNormalizedScrollPosition(
                activeEditor.normalizedScrollPosition
            )
            editor.setSynchronizedSourceSelection(rememberedSelection)
        }
    }

    func activate(_ editor: any MarkdownEditingSurface) {
        attach(editor)
        activeEditor = editor
        rememberedSelection = editor.selectedSourceRange
    }

    func synchronizeScroll(
        from editor: any MarkdownEditingSurface,
        position: CGFloat
    ) {
        guard viewMode == .split, !isSynchronizingScroll else {
            return
        }

        isSynchronizingScroll = true
        defer {
            isSynchronizingScroll = false
        }
        for attachedEditor in liveEditors()
        where !sameEditor(attachedEditor, editor) {
            attachedEditor.setNormalizedScrollPosition(position)
        }
    }

    func synchronizeSelection(
        from editor: any MarkdownEditingSurface,
        selection: NSRange
    ) {
        rememberedSelection = selection
        guard viewMode == .split, !isSynchronizingSelection else {
            return
        }

        isSynchronizingSelection = true
        defer {
            isSynchronizingSelection = false
        }
        for attachedEditor in liveEditors()
        where !sameEditor(attachedEditor, editor) {
            attachedEditor.setSynchronizedSourceSelection(selection)
        }
    }

    func selectionForEditorUpdate(fallback: NSRange) -> NSRange {
        viewMode == .split ? rememberedSelection : fallback
    }

    func detach(_ editor: any MarkdownEditingSurface) {
        let wasActive = activeEditor.map { sameEditor($0, editor) } ?? false
        if wasActive {
            rememberedSelection = editor.selectedSourceRange
        }
        attachedEditors.removeAll {
            guard let attachedEditor = $0.value else {
                return true
            }
            return sameEditor(attachedEditor, editor)
        }

        guard wasActive else {
            return
        }
        activeEditor = nil
        if let replacement = liveEditors().first {
            activeEditor = replacement
            replacement.setSourceSelection(rememberedSelection)
        }
    }

    func registerUndo(
        _ state: MarkdownEditResult,
        actionName: String,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: self) { session in
            guard let editor = session.currentEditor() else {
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
        let editor = currentEditor()
        editor?.commitPendingComposition()

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

        if let window = editor?.hostingWindow {
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
        guard let editor = currentEditor() else {
            present(error: MarkdownEditorPresentationError.editorUnavailable)
            return
        }
        editor.commitPendingComposition()

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

        if let window = editor.hostingWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    func chooseAndInsertImage() {
        let editor = currentEditor()
        editor?.commitPendingComposition()
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

        if let window = editor?.hostingWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func insertAtSelection(_ text: String) {
        guard let editor = currentEditor() else {
            present(
                error: MarkdownEditorPresentationError.editorUnavailable
            )
            return
        }
        editor.commitPendingComposition()

        let source = editor.sourceText as NSString
        let selection = clamped(
            editor.selectedSourceRange,
            to: source.length
        )
        let mutableSource = NSMutableString(string: source)
        mutableSource.replaceCharacters(in: selection, with: text)
        let insertionLength = (text as NSString).length
        editor.apply(
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
        guard let editor = currentEditor() else {
            present(error: MarkdownEditorPresentationError.editorUnavailable)
            return
        }
        editor.commitPendingComposition()
        let result = transform(
            editor.sourceText,
            editor.selectedSourceRange
        )
        editor.apply(result, actionName: actionName)
        editor.focus()
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        if let window = currentEditor()?.hostingWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func currentEditor() -> (any MarkdownEditingSurface)? {
        let editors = liveEditors()
        if let focusedEditor = editors.first(where: \.hasFocus) {
            activeEditor = focusedEditor
            rememberedSelection = focusedEditor.selectedSourceRange
            return focusedEditor
        }
        if let activeEditor,
            editors.contains(where: { sameEditor($0, activeEditor) })
        {
            return activeEditor
        }

        activeEditor = editors.first
        return activeEditor
    }

    private func liveEditors() -> [any MarkdownEditingSurface] {
        attachedEditors.removeAll { $0.value == nil }
        return attachedEditors.compactMap { $0.value }
    }

    private func sameEditor(
        _ left: any MarkdownEditingSurface,
        _ right: any MarkdownEditingSurface
    ) -> Bool {
        (left as AnyObject) === (right as AnyObject)
    }

    private func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

private final class WeakEditingSurface {
    weak var value: (any MarkdownEditingSurface)?

    init(_ value: any MarkdownEditingSurface) {
        self.value = value
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
