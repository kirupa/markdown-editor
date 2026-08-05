import MarkdownEditorUI
import SwiftUI

/// A popover modeled on the "Customize Theme" dialog at kirupa.com: a color
/// row, a light/dark background toggle, and explicit Apply/Cancel buttons.
struct ThemePickerPopover: View {
    @Binding var colorTheme: EditorColorTheme
    @Binding var isPresented: Bool

    @State private var draft: EditorColorTheme

    init(
        colorTheme: Binding<EditorColorTheme>,
        isPresented: Binding<Bool>
    ) {
        _colorTheme = colorTheme
        _isPresented = isPresented
        _draft = State(initialValue: colorTheme.wrappedValue)
    }

    private let columns = Array(
        repeating: GridItem(.fixed(26), spacing: 8),
        count: 8
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Customize Theme")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(EditorThemeColor.allCases) { themeColor in
                        swatch(for: themeColor)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Background")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Picker("Background", selection: $draft.mode) {
                    ForEach(EditorAppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            preview

            Divider()

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Apply") {
                    colorTheme = draft
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { draft = colorTheme }
    }

    private func swatch(for themeColor: EditorThemeColor) -> some View {
        // Fill and border come straight from `#themeChooser #theme_<color>`
        // in kirupa.css so the swatches read exactly like the website's.
        let isSelected = draft.color == themeColor
        let glow = Color(nsColor: themeColor.swatchBorderColor)

        return Button {
            draft.color = themeColor
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: themeColor.swatchFillColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            Color(nsColor: themeColor.swatchBorderColor),
                            lineWidth: 3
                        )
                }
                .frame(width: 26, height: 26)
                .shadow(
                    color: isSelected ? glow : .clear,
                    radius: isSelected ? 5 : 0
                )
                .scaleEffect(isSelected ? 1.15 : 1)
                .animation(.easeOut(duration: 0.12), value: isSelected)
        }
        .buttonStyle(.plain)
        .help(themeColor.title)
        .accessibilityLabel("\(themeColor.title) theme")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Heading")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(nsColor: draft.primaryTextColor))
            Text(verbatim: "Body paragraph text")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: draft.primaryTextColor))
            Text(verbatim: "let code = true")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: draft.primaryTextColor))
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Color(nsColor: draft.codeBlockBackgroundColor))
                .clipShape(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
            Text(verbatim: "secondary label")
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: draft.secondaryTextColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: draft.editorBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color(nsColor: draft.separatorColor),
                    lineWidth: 1
                )
        }
        .accessibilityLabel("Preview of \(draft.title)")
    }
}
