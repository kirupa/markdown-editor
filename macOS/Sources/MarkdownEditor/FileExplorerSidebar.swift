import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

struct FileExplorerSidebar: View {
    @Environment(\.openDocument) private var openDocument
    @ObservedObject var session: MarkdownEditorSession
    @ObservedObject private var model: FileExplorerModel
    let colorTheme: EditorColorTheme

    init(
        session: MarkdownEditorSession,
        colorTheme: EditorColorTheme
    ) {
        self.session = session
        self.colorTheme = colorTheme
        model = session.fileExplorer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.rootURL != nil {
                FileExplorerOutlineView(
                    model: model,
                    currentFileURL: session.fileURL,
                    colorTheme: colorTheme,
                    onOpen: open
                )
            } else {
                emptyState
            }
        }
        .background(colorTheme.sidebarBackground)
        .alert(item: $model.presentedAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: alert.message.map(Text.init),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func open(_ entry: FileTreeEntry) {
        if FileTreeScanner.isMarkdownDocument(entry.url) {
            Task { @MainActor in
                do {
                    try await openDocument(at: entry.url)
                } catch {
                    model.report(error)
                }
            }
        } else {
            model.openExternally(entry)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.ancestorURLs, id: \.self) { url in
                    Button {
                        model.setUserSelectedRoot(url)
                    } label: {
                        Label(
                            model.folderName(for: url),
                            systemImage: url == model.rootURL
                                ? "checkmark"
                                : "folder"
                        )
                    }
                }

                if model.rootURL != nil {
                    Divider()
                }

                Button("Choose Folder…") {
                    session.chooseExplorerFolder()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(model.displayedFolderName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .help(model.rootURL?.path ?? "Choose a folder")

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh Explorer")
            .disabled(model.rootURL == nil)

            Button {
                model.showDocumentDirectory(for: session.fileURL)
            } label: {
                Image(systemName: "doc.text.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Show Current Document Folder")
            .accessibilityLabel("Show Current Document Folder")
            .disabled(session.fileURL == nil)
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No Folder Open")
                .font(.headline)
            Text("Save this document or choose a folder to browse its files.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 190)
            Button("Open Folder…") {
                session.chooseExplorerFolder()
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}
