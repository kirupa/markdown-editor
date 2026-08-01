import SwiftUI

private struct MarkdownEditorSessionKey: FocusedValueKey {
    typealias Value = MarkdownEditorSession
}

extension FocusedValues {
    var markdownEditorSession: MarkdownEditorSession? {
        get { self[MarkdownEditorSessionKey.self] }
        set { self[MarkdownEditorSessionKey.self] = newValue }
    }
}

struct MarkdownEditorCommands: Commands {
    @FocusedValue(\.markdownEditorSession)
    private var session

    var body: some Commands {
        CommandMenu("Insert") {
            Button("Image…") {
                session?.chooseAndInsertImage()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(session == nil)
        }
    }
}
