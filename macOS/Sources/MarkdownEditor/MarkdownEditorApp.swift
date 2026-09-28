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
        // The window opens big enough to hold what it opens showing.
        //
        // Only used when there is nothing to restore: SwiftUI applies this to
        // a genuinely new window and leaves a restored one at the size it was
        // last left, which is the behaviour a reader who has resized a window
        // expects and the reason this is not done by setting a frame.
        .defaultSize(
            width: Layout.defaultWindowWidth,
            height: Layout.defaultWindowHeight
        )
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
