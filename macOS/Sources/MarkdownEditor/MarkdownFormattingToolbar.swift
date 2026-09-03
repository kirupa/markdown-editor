import MarkdownEditorUI
import SwiftUI

struct MarkdownFormattingToolbar: ToolbarContent {
    @ObservedObject var session: MarkdownEditorSession
    @Binding var colorTheme: EditorColorTheme
    @State private var isThemePickerPresented = false

    var body: some ToolbarContent {
        // X-18: the explorer is closed by default, so there has to be somewhere
        // obvious to open it. First position, before the view switcher, is
        // where a sidebar toggle lives in every other Mac app.
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

        ToolbarItem(placement: .navigation) {
            Picker(
                "Editor View",
                selection: Binding(
                    get: { session.viewMode },
                    set: { session.setViewMode($0) }
                )
            ) {
                ForEach(EditorViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .help("Switch among Rich Text, Markdown, and Split views")
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

        // The formatting controls are *not* here. They live above the
        // document, the width of the column — see `FormattingBar`. What is
        // left in the window's toolbar is what acts on the window rather than
        // on the words: the explorer, the view mode, the theme, the critique.
    }
}
