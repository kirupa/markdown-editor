import SwiftUI

struct MarkdownEditorView: View {
    @Binding private var document: MarkdownDocument
    @StateObject private var session: MarkdownEditorSession
    private let fileURL: URL?

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        _session = StateObject(
            wrappedValue: MarkdownEditorSession(fileURL: fileURL)
        )
        self.fileURL = fileURL
    }

    var body: some View {
        SourceTextEditor(
            text: $document.text,
            session: session
        )
        .frame(minWidth: 620, minHeight: 420)
        .focusedSceneValue(\.markdownEditorSession, session)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    session.chooseAndInsertImage()
                } label: {
                    Label("Add Image", systemImage: "photo.badge.plus")
                }
                .help("Copy an image beside this document and insert a reference")
            }
        }
        .onChange(of: fileURL) { newFileURL in
            session.fileURL = newFileURL
        }
    }
}
