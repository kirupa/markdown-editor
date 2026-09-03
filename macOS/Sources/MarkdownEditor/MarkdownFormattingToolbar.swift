import MarkdownEditorUI
import SwiftUI

/// What is left in the window's title bar.
///
/// Three controls: the explorer, the theme, the critique. Everything that acts
/// on the *words* moved onto the document itself — see `FormattingBar` — so
/// what remains is only what acts on the window, and the header is as close to
/// empty as it can be while still opening those three things.
///
/// They are ordinary macOS toolbar buttons. They were square outlined blocks
/// that inverted under the pointer, which is the right treatment for the
/// critique pad and the wrong one here: a title bar full of drawn-on controls
/// stops looking like a Mac window and starts looking like a costume.
struct MarkdownFormattingToolbar: ToolbarContent {
    @ObservedObject var session: MarkdownEditorSession
    @Binding var colorTheme: EditorColorTheme
    @State private var isThemePickerPresented = false

    var body: some ToolbarContent {
        // X-18: the explorer is closed by default, so there has to be somewhere
        // obvious to open it. First position is where a sidebar toggle lives in
        // every other Mac app.
        ToolbarItem(placement: .navigation) {
            Button {
                session.toggleExplorer()
            } label: {
                Label(
                    session.isExplorerVisible
                        ? "Hide File Explorer"
                        : "Show File Explorer",
                    systemImage: "sidebar.leading"
                )
            }
            .help(
                session.isExplorerVisible
                    ? "Hide the file explorer (⌃⌘S)"
                    : "Show the file explorer (⌃⌘S)"
            )
            .accessibilityAddTraits(
                session.isExplorerVisible ? [.isSelected] : []
            )
        }

        ToolbarItem {
            Button {
                isThemePickerPresented = true
            } label: {
                Label("Customize Theme", systemImage: "paintpalette")
            }
            .help("Choose a kirupa.com color and a light or dark background")
            .popover(
                isPresented: $isThemePickerPresented,
                arrowEdge: .bottom
            ) {
                ThemePickerPopover(
                    colorTheme: $colorTheme,
                    isPresented: $isThemePickerPresented
                )
            }
        }
    }
}
