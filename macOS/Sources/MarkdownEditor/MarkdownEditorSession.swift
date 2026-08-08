import AppKit
import MarkdownEditorCore
import MarkdownEditorUI
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

    /// The image the selection sits on, if any.
    ///
    /// A rendered image is a single atomic character, so "on" means the caret
    /// is inside or immediately after it — the same span the reading view
    /// highlights.
    func imageAtSelection() -> (range: NSRange, tag: MarkdownImageTag.Parsed)? {
        guard let editor = currentEditor() else { return nil }
        let text = editor.sourceText as NSString
        let selection = clamped(editor.selectedSourceRange, to: text.length)

        for span in MarkdownRenderer.render(editor.sourceText).spans {
            guard case .image = span.style else { continue }
            let start = span.sourceRange.location
            let end = NSMaxRange(span.sourceRange)
            guard selection.location >= start, selection.location <= end else {
                continue
            }
            guard
                let tag = MarkdownFormatting.readImage(
                    text,
                    range: span.sourceRange
                )
            else { continue }
            return (span.sourceRange, tag)
        }
        return nil
    }

    var canResizeImageAtSelection: Bool { imageAtSelection() != nil }

    /// Set the size of the image at the selection.
    ///
    /// The two fields drive each other through the image's own proportions, so
    /// a picture cannot be squashed by accident.
    func chooseImageSize() {
        let editor = currentEditor()
        editor?.commitPendingComposition()

        guard let image = imageAtSelection() else {
            present(error: MarkdownEditorPresentationError.noImageAtSelection)
            return
        }

        let natural = naturalSize(of: image.tag.destination)
        let controller = MarkdownImageSizeAccessory(
            width: image.tag.width,
            height: image.tag.height,
            natural: natural
        )

        let alert = NSAlert()
        alert.messageText = "Image Size"
        alert.informativeText = natural == nil
            ? """
                Set a width or a height in pixels. The image could not be \
                measured, so the other dimension is left to the renderer.
                """
            : """
                Set a width or a height in pixels. The other follows to keep \
                the image in proportion.
                """
        alert.accessoryView = controller.view
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            let size: MarkdownImageTag.Size
            switch response {
            case .alertFirstButtonReturn:
                size = controller.size
            case .alertSecondButtonReturn:
                size = .none
            default:
                return
            }
            self?.applyImageSize(size, to: image.range)
        }

        if let window = editor?.hostingWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func applyImageSize(
        _ size: MarkdownImageTag.Size,
        to range: NSRange
    ) {
        guard let editor = currentEditor() else {
            present(error: MarkdownEditorPresentationError.editorUnavailable)
            return
        }
        let result = MarkdownFormatting.setImageSize(
            in: editor.sourceText,
            range: range,
            size: size
        )
        editor.apply(result, actionName: "Image Size")
        editor.focus()
    }

    /// The image's own pixel dimensions, so a resize can keep its shape.
    ///
    /// An image referenced by web address is measured too, but only from what
    /// the renderer has already downloaded — opening this sheet must not start
    /// a fetch and then block on it. An address not yet loaded simply has no
    /// natural size, which the sheet says rather than guessing at.
    private func naturalSize(
        of destination: String
    ) -> MarkdownImageTag.Size? {
        if let remote = RemoteImageStore.shared.loadedImage(for: destination) {
            return Self.pixelSize(of: remote)
        }
        guard let fileURL else { return nil }
        let decoded = destination.removingPercentEncoding ?? destination
        guard !decoded.contains("://") else { return nil }
        let url = URL(
            fileURLWithPath: decoded,
            relativeTo: fileURL.deletingLastPathComponent()
        )
        guard let image = NSImage(contentsOf: url) else { return nil }
        return Self.pixelSize(of: image)
    }

    private static func pixelSize(of image: NSImage) -> MarkdownImageTag.Size? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return MarkdownImageTag.Size(
            width: Int(image.size.width.rounded()),
            height: Int(image.size.height.rounded())
        )
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
            frame: NSRect(x: 0, y: 0, width: 420, height: 24)
        )
        destinationField.placeholderString = "https://example.com"
        destinationField.stringValue = "https://"
        destinationField.usesSingleLineMode = true
        destinationField.lineBreakMode = .byClipping
        destinationField.cell?.wraps = false
        destinationField.cell?.isScrollable = true

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

    /// Ask where the image comes from, then take that route.
    ///
    /// A file has to be copied into the assets folder beside the document and a
    /// URL must not be, so the choice has to be made before either route
    /// starts — the open panel can no longer just appear.
    func chooseAndInsertImage() {
        let editor = currentEditor()
        editor?.commitPendingComposition()

        let alert = NSAlert()
        alert.messageText = "Add an image"
        alert.informativeText = """
            Choose a file to copy in beside this document, or link to an image \
            already on the web.
            """
        alert.addButton(withTitle: "Choose File…")
        alert.addButton(withTitle: "Image Address…")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.chooseImageFile()
            case .alertSecondButtonReturn:
                self?.chooseImageAddress()
            default:
                break
            }
        }

        if let window = editor?.hostingWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// Reference an image that is already on the web. Nothing is copied.
    func chooseImageAddress() {
        let editor = currentEditor()

        // A URL is one long unbreakable token, so a field that wraps turns a
        // pasted address into a ragged block and hides its end. `usesSingleLineMode`
        // alone is not enough — the cell must also be told to scroll instead of
        // wrap, or the text is simply clipped at the right edge.
        let destinationField = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 420, height: 24)
        )
        destinationField.placeholderString = "https://example.com/photo.png"
        destinationField.stringValue = "https://"
        destinationField.usesSingleLineMode = true
        destinationField.lineBreakMode = .byClipping
        destinationField.cell?.wraps = false
        destinationField.cell?.isScrollable = true

        let alert = NSAlert()
        alert.messageText = "Image address"
        alert.informativeText =
            "The image stays where it is; this document points at it."
        alert.accessoryView = destinationField
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")

        let completion: (NSApplication.ModalResponse) -> Void = {
            [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let destination = destinationField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty, destination != "https://" else {
                return
            }
            self?.applyFormatting("Add Image") { text, selection in
                MarkdownFormatting.insertImage(
                    destination: destination,
                    in: text,
                    selection: selection
                )
            }
        }

        if let window = editor?.hostingWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func chooseImageFile() {
        let editor = currentEditor()
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
    case noImageAtSelection

    var errorDescription: String? {
        switch self {
        case .editorUnavailable:
            "The requested edit could not be applied."
        case .noImageAtSelection:
            "There is no image at the insertion point."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .editorUnavailable:
            "Click in the editor and try adding the image again."
        case .noImageAtSelection:
            "Select an image, or place the insertion point on one, and try again."
        }
    }
}
