import MarkdownEditorUI
import SwiftUI

@main
struct MarkdownEditorApp: App {
    @NSApplicationDelegateAdaptor(MarkdownEditorAppDelegate.self)
    private var appDelegate
    @AppStorage(EditorThemeColor.storageKey)
    private var themeColorRawValue = EditorThemeColor.blue.rawValue
    @AppStorage(EditorAppearanceMode.storageKey)
    private var appearanceModeRawValue =
        EditorAppearanceMode.systemDefault.rawValue

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { configuration in
            MarkdownEditorView(
                document: configuration.$document,
                fileURL: configuration.fileURL,
                themeColorRawValue: $themeColorRawValue,
                appearanceModeRawValue: $appearanceModeRawValue
            )
        }
        .commands {
            MarkdownEditorCommands()
        }
    }
}
