import MarkdownEditorCore
import MarkdownEditorUI
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The editor screen.
///
/// One view for both idioms rather than two. The only real difference is that
/// an iPad is wide enough to show both panes at once, so Split is offered
/// there and not on a phone — everything else, including the full formatting
/// set, is identical, because a smaller screen is not a reason to be given a
/// less capable editor.
struct DocumentEditorView: View {
    @Binding var document: MarkdownDocument
    let documentURL: URL?

    @EnvironmentObject private var themeStore: EditorThemeStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var controller = EditorController()

    @State private var photoItem: PhotosPickerItem?
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFileImporter = false
    @State private var linkDestination = ""
    @State private var isAskingForLink = false

    private var theme: EditorColorTheme {
        themeStore.theme
    }

    private var allowsSplit: Bool {
        horizontalSizeClass == .regular
    }

    private var availableModes: [EditorViewMode] {
        allowsSplit ? EditorViewMode.allCases : [.rich, .source]
    }

    /// The mode actually shown, which is the remembered one unless this size
    /// class cannot offer it.
    ///
    /// Kept separate from the stored preference so that an iPad user who
    /// chose Split and then slides the app into a compact width gets Rich
    /// Text for the moment without losing Split when they slide back.
    private var effectiveMode: EditorViewMode {
        availableModes.contains(controller.viewMode) ? controller.viewMode : .rich
    }

    private var modeSelection: Binding<EditorViewMode> {
        Binding(
            get: { effectiveMode },
            set: { controller.viewMode = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkdownFormattingBar(
                text: $document.text,
                controller: controller,
                theme: theme,
                onInsertLink: { isAskingForLink = true },
                onInsertImage: { isShowingPhotoPicker = true }
            )
            Divider()
            editors
        }
        .background(Color(platformColor: theme.canvasBackgroundColor))
        .toolbar { toolbarContent }
        .toolbarBackground(
            Color(platformColor: theme.sidebarBackgroundColor),
            for: .navigationBar
        )
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $controller.isShowingThemePicker) {
            ThemePickerSheet(theme: $themeStore.theme)
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $photoItem,
            matching: .images
        )
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.image]
        ) { result in
            switch result {
            case .success(let url):
                importImageFile(at: url)
            case .failure(let error):
                controller.report(error)
            }
        }
        .alert("Insert Link", isPresented: $isAskingForLink) {
            TextField("https://example.com", text: $linkDestination)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { linkDestination = "" }
            Button("Insert") { insertLink() }
        } message: {
            Text("The selected text becomes the link's label.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var editors: some View {
        switch effectiveMode {
        case .rich:
            richEditor
        case .source:
            sourceEditor
        case .split:
            HStack(spacing: 0) {
                richEditor
                Divider()
                sourceEditor
            }
        }
    }

    private var richEditor: some View {
        MarkdownRichTextEditor(
            text: $document.text,
            controller: controller,
            documentURL: documentURL,
            theme: theme
        )
    }

    private var sourceEditor: some View {
        MarkdownSourceTextEditor(
            text: $document.text,
            controller: controller,
            theme: theme
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The document title and its rename/duplicate menu live in the centre
        // of the navigation bar and belong to DocumentGroup. Putting the mode
        // switch there displaces them, so the segmented control is only used
        // where there is room beside them; a phone gets a menu instead.
        if allowsSplit {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("View", selection: modeSelection) {
                    ForEach(availableModes) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .labelStyle(.iconOnly)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("View", selection: modeSelection) {
                        ForEach(availableModes) { mode in
                            Label(mode.rawValue, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                } label: {
                    Label("View", systemImage: effectiveMode.systemImage)
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                controller.isShowingThemePicker = true
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
        }
    }

    private func insertLink() {
        let destination = linkDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        linkDestination = ""
        controller.apply(
            { text, selection in
                MarkdownFormatting.insertLink(
                    destination: destination.isEmpty
                        ? "https://" : destination,
                    in: text,
                    selection: selection
                )
            },
            to: $document.text
        )
    }

    /// Copies a picked photo next to the document and inserts a reference.
    ///
    /// Photos are not files on disk until asked for, so the bytes come back
    /// through the picker and are written into the same `<stem>.assets` folder
    /// the Mac app uses, by the same shared importer.
    private func importPhoto(_ item: PhotosPickerItem) async {
        photoItem = nil
        guard let documentURL else {
            controller.errorMessage = """
                Save this document before adding an image, so the image has \
                somewhere to live beside it.
                """
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self)
            else {
                controller.errorMessage = "That image could not be read."
                return
            }
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(
                    item.supportedContentTypes.first?
                        .preferredFilenameExtension ?? "png"
                )
            try data.write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try insertImage(from: temporary, documentURL: documentURL)
        } catch {
            controller.report(error)
        }
    }

    private func importImageFile(at url: URL) {
        guard let documentURL else {
            controller.errorMessage = """
                Save this document before adding an image, so the image has \
                somewhere to live beside it.
                """
            return
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            try insertImage(from: url, documentURL: documentURL)
        } catch {
            controller.report(error)
        }
    }

    private func insertImage(from url: URL, documentURL: URL) throws {
        let imported = try MarkdownImageImporter().importImage(
            at: url,
            forDocumentAt: documentURL
        )
        controller.insert(imported.markdownReference, into: $document.text)
    }
}
