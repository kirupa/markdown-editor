import SwiftUI

@main
struct MarkdownEditorApp: App {
    @AppStorage(EditorColorTheme.storageKey)
    private var colorThemeRawValue = EditorColorTheme.systemDefault.rawValue

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            MarkdownEditorView(
                document: configuration.$document,
                fileURL: configuration.fileURL,
                colorThemeRawValue: $colorThemeRawValue
            )
        }
        .commands {
            MarkdownEditorCommands()
        }
    }
}
