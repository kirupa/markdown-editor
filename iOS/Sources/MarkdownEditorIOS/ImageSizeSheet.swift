import MarkdownEditorCore
import SwiftUI

/// Setting the width and height of an image.
///
/// The two fields drive each other: typing in one derives the other from the
/// image's own proportions, so a picture cannot be squashed by accident. The
/// number that was typed is always the one kept exactly — otherwise the field
/// fights the person typing in it.
struct ImageSizeSheet: View {
    let natural: MarkdownImageTag.Size?
    let onApply: (MarkdownImageTag.Size) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var widthText: String
    @State private var heightText: String

    init(
        width: Int?,
        height: Int?,
        natural: MarkdownImageTag.Size?,
        onApply: @escaping (MarkdownImageTag.Size) -> Void
    ) {
        self.natural = natural
        self.onApply = onApply
        _widthText = State(initialValue: width.map(String.init) ?? "")
        _heightText = State(initialValue: height.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    dimensionRow("Width", text: $widthText, edited: .width)
                    dimensionRow("Height", text: $heightText, edited: .height)
                } footer: {
                    Text(
                        natural == nil
                            ? """
                                The image could not be measured, so the other \
                                dimension is left to the renderer.
                                """
                            : """
                                Set a width or a height in pixels. The other \
                                follows to keep the image in proportion.
                                """
                    )
                }

                Section {
                    Button("Use the image's own size", role: .destructive) {
                        onApply(.none)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Image Size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(currentSize)
                        dismiss()
                    }
                }
            }
        }
    }

    private func dimensionRow(
        _ title: String,
        text: Binding<String>,
        edited: MarkdownImageTag.Dimension
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("auto", text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: text.wrappedValue) { _, _ in
                        recalculate(edited: edited)
                    }
                Text("px").foregroundStyle(.secondary)
            }
        }
    }

    private var currentSize: MarkdownImageTag.Size {
        MarkdownImageTag.Size(
            width: pixelCount(widthText),
            height: pixelCount(heightText)
        )
    }

    private func recalculate(edited: MarkdownImageTag.Dimension) {
        // An empty field is mid-edit, not a request to clear the size; the
        // button in the second section is how a size is removed.
        let typed = edited == .width ? widthText : heightText
        guard !typed.isEmpty else { return }

        let derived = MarkdownImageTag.proportionalSize(
            currentSize,
            natural: natural,
            edited: edited
        )
        switch edited {
        case .width:
            heightText = derived.height.map(String.init) ?? ""
        case .height:
            widthText = derived.width.map(String.init) ?? ""
        }
    }

    private func pixelCount(_ value: String) -> Int? {
        guard let number = Int(value.trimmingCharacters(in: .whitespaces)),
              number > 0
        else { return nil }
        return number
    }
}
