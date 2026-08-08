import AppKit
import MarkdownEditorCore

/// The width and height fields in the Image Size sheet.
///
/// The two fields drive each other: typing in one derives the other from the
/// image's own proportions, so a picture cannot be squashed by accident. The
/// number that was typed is always the one kept exactly — otherwise the field
/// fights the person typing in it.
@MainActor
final class MarkdownImageSizeAccessory: NSObject, NSTextFieldDelegate {
    let view: NSView

    private let widthField: NSTextField
    private let heightField: NSTextField
    private let natural: MarkdownImageTag.Size?

    init(width: Int?, height: Int?, natural: MarkdownImageTag.Size?) {
        self.natural = natural
        widthField = NSTextField()
        heightField = NSTextField()

        let widthLabel = MarkdownImageSizeAccessory.label("Width:")
        let heightLabel = MarkdownImageSizeAccessory.label("Height:")

        for field in [widthField, heightField] {
            field.alignment = .right
            field.placeholderString = "auto"
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
        }
        widthField.stringValue = width.map(String.init) ?? ""
        heightField.stringValue = height.map(String.init) ?? ""

        let pixelsAfterWidth = MarkdownImageSizeAccessory.label("px")
        let pixelsAfterHeight = MarkdownImageSizeAccessory.label("px")

        let row = NSStackView(views: [
            widthLabel,
            widthField,
            pixelsAfterWidth,
            heightLabel,
            heightField,
            pixelsAfterHeight
        ])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .firstBaseline
        row.frame = NSRect(x: 0, y: 0, width: 380, height: 26)
        view = row

        super.init()
        widthField.delegate = self
        heightField.delegate = self
    }

    /// The size the fields currently describe.
    var size: MarkdownImageTag.Size {
        MarkdownImageTag.Size(
            width: pixelCount(widthField.stringValue),
            height: pixelCount(heightField.stringValue)
        )
    }

    nonisolated func controlTextDidChange(_ notification: Notification) {
        let edited = notification.object as? NSTextField
        MainActor.assumeIsolated { self.textDidChange(in: edited) }
    }

    private func textDidChange(in edited: NSTextField?) {
        guard let edited else { return }
        let dimension: MarkdownImageTag.Dimension =
            edited === widthField ? .width : .height

        // An empty field is mid-edit, not a request to clear the size; the
        // sheet's Reset button is how a size is removed.
        guard !edited.stringValue.isEmpty else { return }

        let derived = MarkdownImageTag.proportionalSize(
            size,
            natural: natural,
            edited: dimension
        )
        switch dimension {
        case .width:
            heightField.stringValue = derived.height.map(String.init) ?? ""
        case .height:
            widthField.stringValue = derived.width.map(String.init) ?? ""
        }
    }

    private func pixelCount(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard let number = Int(trimmed), number > 0 else { return nil }
        return number
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}
