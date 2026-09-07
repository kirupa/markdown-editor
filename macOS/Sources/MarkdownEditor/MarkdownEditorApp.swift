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

        // The standard place: KONVO ▸ Settings, ⌘,. A reader looking for a
        // preference looks there before anywhere else.
        Settings {
            CritiqueSettingsView()
        }
    }
}
