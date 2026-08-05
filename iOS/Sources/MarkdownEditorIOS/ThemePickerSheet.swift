import MarkdownEditorUI
import SwiftUI

/// The theme picker.
///
/// The same eight kirupa.com colors on the same independent light/dark axis
/// the Mac app and the web app offer, from the same shared palette — so a
/// document looks the same on a phone as it does on a desktop.
struct ThemePickerSheet: View {
    @Binding var theme: EditorColorTheme
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 12)]

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $theme.mode) {
                        ForEach(EditorAppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Color") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(EditorThemeColor.allCases) { color in
                            swatch(for: color)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Preview") {
                    preview
                }
            }
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func swatch(for color: EditorThemeColor) -> some View {
        let candidate = EditorColorTheme(color: color, mode: theme.mode)
        let isSelected = theme.color == color
        return Button {
            theme.color = color
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(platformColor: candidate.accentColor))
                    .frame(height: 40)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                Color.primary.opacity(isSelected ? 0.9 : 0.1),
                                lineWidth: isSelected ? 3 : 1
                            )
                    }
                Text(color.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heading")
                .font(.headline)
                .foregroundStyle(Color(platformColor: theme.primaryTextColor))
            Text("Body text, and a secondary line beneath it.")
                .font(.subheadline)
                .foregroundStyle(Color(platformColor: theme.secondaryTextColor))
            Text("inline code")
                .font(.system(.footnote, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Color(platformColor: theme.inlineCodeBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .foregroundStyle(Color(platformColor: theme.primaryTextColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            Color(platformColor: theme.editorBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
