import MarkdownEditorUI
import SwiftUI

/// What is left in the window's title bar.
///
/// Three controls: the explorer, the theme, the critique. Everything that acts
/// on the *words* moved onto the document itself — see `FormattingBar` — so
/// what remains is only what acts on the window, and the header is as close to
/// empty as it can be while still opening those three things.
///
/// They are drawn as square outlined blocks rather than as system buttons, so
/// the header belongs to the same design as the bar below it: an edge, a fill,
/// no rounding, no capsule.
struct MarkdownFormattingToolbar: ToolbarContent {
    @ObservedObject var session: MarkdownEditorSession
    @Binding var colorTheme: EditorColorTheme
    @State private var isThemePickerPresented = false

    var body: some ToolbarContent {
        // X-18: the explorer is closed by default, so there has to be somewhere
        // obvious to open it. First position is where a sidebar toggle lives in
        // every other Mac app.
        ToolbarItem(placement: .navigation) {
            HeaderButton(
                symbol: "sidebar.leading",
                colorTheme: colorTheme,
                isOn: session.isExplorerVisible,
                help: session.isExplorerVisible
                    ? "Hide the file explorer (⌃⌘S)"
                    : "Show the file explorer (⌃⌘S)"
            ) {
                session.toggleExplorer()
            }
            .accessibilityLabel(
                session.isExplorerVisible
                    ? "Hide File Explorer"
                    : "Show File Explorer"
            )
            .accessibilityAddTraits(
                session.isExplorerVisible ? [.isSelected] : []
            )
        }

        ToolbarItem {
            HeaderButton(
                symbol: "paintpalette",
                colorTheme: colorTheme,
                help: "Choose a kirupa.com color and a light or dark background"
            ) {
                isThemePickerPresented = true
            }
            .accessibilityLabel("Customize Theme")
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

/// One square control in the window's header.
///
/// The same object as a `FormattingBar` button and deliberately so — an
/// outlined square that inverts under the pointer.
struct HeaderButton: View {
    let symbol: String
    let colorTheme: EditorColorTheme
    var isOn: Bool = false
    var isEnabled: Bool = true
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 22)
                .foregroundStyle(
                    filled
                        ? PixelStyle.barSurface(colorTheme)
                        : PixelStyle.ink(colorTheme).opacity(isEnabled ? 1 : 0.35)
                )
                .background(
                    ZStack {
                        Rectangle()
                            .fill(
                                filled
                                    ? PixelStyle.ink(colorTheme)
                                    : PixelStyle.barSurface(colorTheme)
                            )
                        Rectangle()
                            .strokeBorder(
                                PixelStyle.ink(colorTheme)
                                    .opacity(isEnabled ? 1 : 0.35),
                                lineWidth: PixelStyle.border
                            )
                    }
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 && isEnabled }
        .help(help)
    }

    private var filled: Bool {
        isEnabled && (isHovered || isOn)
    }
}
