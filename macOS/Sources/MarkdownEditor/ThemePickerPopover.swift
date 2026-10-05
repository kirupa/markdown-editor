import MarkdownEditorUI
import SwiftUI

/// A popover modeled on the "Customize Theme" dialog at kirupa.com: a color
/// row, a light/dark background toggle, the face the document is set in and
/// how large it is drawn.
///
/// Every choice is applied as it is made, so the document behind the popover
/// is the preview. It used to hold a draft until Apply and show it in a small
/// sample box, which meant judging a face or a size from three lines of
/// placeholder text with the real page a few centimetres away, unchanged.
/// Cancel and Escape put back the theme the popover opened with; Done, or
/// clicking away, keeps what is on the page.
struct ThemePickerPopover: View {
    @Binding var colorTheme: EditorColorTheme
    @Binding var isPresented: Bool

    /// The theme as it was when the popover opened, for Cancel.
    @State private var original: EditorColorTheme

    init(
        colorTheme: Binding<EditorColorTheme>,
        isPresented: Binding<Bool>
    ) {
        _colorTheme = colorTheme
        _isPresented = isPresented
        _original = State(initialValue: colorTheme.wrappedValue)
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

                Picker("Background", selection: $colorTheme.mode) {
                    ForEach(EditorAppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Font")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                fontMenu

                textSizeSlider
            }

            Divider()

            HStack {
                Button("Cancel") {
                    colorTheme = original
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .help("Put back the theme you started with")

                Spacer()

                Button("Done") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { original = colorTheme }
    }

    /// The face the document is set in, chosen from exactly the faces the
    /// critique's hand menu offers, shown the same way.
    private var fontMenu: some View {
        Menu {
            TypefaceMenuItems(selected: colorTheme.typeface) { candidate in
                colorTheme.typeface = candidate
            }
        } label: {
            Text(colorTheme.typeface.title)
        }
        .accessibilityLabel("Font")
        // The name alone was read as "Font", with no value to say which
        // face is chosen; the one the writer can see is now its value.
        .accessibilityValue(colorTheme.typeface.title)
        .help("The face the document is set in")
    }

    /// How large the document is drawn, beneath the face because it is the
    /// face's correction: two hands at the same size can look a size apart.
    /// 75% to 150% in steps of 5%, so 100% is always a stop.
    private var textSizeSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: textScalePercent)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Named once, by its own label. Given a second name on top, it was
            // read as "Size, Text size".
            Slider(
                value: $colorTheme.textScale,
                in: EditorColorTheme.textScaleRange,
                step: 0.05
            ) {
                Text("Text size")
            } minimumValueLabel: {
                // Each A is a button: a click steps the size by 5%, and so
                // does VoiceOver's press. Hidden, it was a button with no
                // name, which VoiceOver stopped on and read as nothing.
                Text(verbatim: "A")
                    .font(.system(size: 10))
                    .accessibilityLabel("Smaller text")
            } maximumValueLabel: {
                Text(verbatim: "A")
                    .font(.system(size: 16))
                    .accessibilityLabel("Larger text")
            }
            .labelsHidden()
            .accessibilityValue(textScalePercent)
            .help("How large the document's text is drawn")
        }
    }

    private var textScalePercent: String {
        "\(Int((colorTheme.textScale * 100).rounded()))%"
    }

    private func swatch(for themeColor: EditorThemeColor) -> some View {
        // Fill and border come straight from `#themeChooser #theme_<color>`
        // in kirupa.css so the swatches read exactly like the website's.
        let isSelected = colorTheme.color == themeColor
        let glow = Color(nsColor: themeColor.swatchBorderColor)

        return Button {
            colorTheme.color = themeColor
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
}
