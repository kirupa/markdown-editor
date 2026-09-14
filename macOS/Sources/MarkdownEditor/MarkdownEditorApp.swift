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
        // What a window opens at on a first run: wide enough for the writing
        // column *and* the comments rail beside it, because the rail is there
        // from the moment the document is. Anything saved for a window — a
        // restored session, a size set by hand — still wins over this; it is
        // the default, not a rule.
        .defaultSize(Layout.defaultWindowContentSize)
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
