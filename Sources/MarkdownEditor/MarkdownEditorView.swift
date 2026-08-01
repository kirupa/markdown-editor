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
        Group {
            switch session.viewMode {
            case .rich:
                RichTextEditor(
                    text: $document.text,
                    documentURL: fileURL,
                    session: session
                )
            case .source:
                SourceTextEditor(
                    text: $document.text,
                    session: session
                )
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .focusedSceneValue(\.markdownEditorSession, session)
        .toolbar {
            MarkdownFormattingToolbar(session: session)
        }
        .onChange(of: fileURL) { newFileURL in
            session.fileURL = newFileURL
        }
    }
}
