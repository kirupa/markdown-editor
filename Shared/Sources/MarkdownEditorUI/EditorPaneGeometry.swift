import CoreGraphics

/// The widths of the two things a document window can resize: the file
/// explorer that floats over the document, and the reading measure the
/// rendered text is set in.
///
/// This is arithmetic, not layout, so it lives here where it can be tested
/// rather than inside a `View` where it cannot. Both platforms clamp the same
/// way; a width that is out of range on a Mac is out of range on an iPad.
public enum EditorPaneGeometry {
    /// How much of the document has to stay uncovered by the explorer.
    ///
    /// The explorer floats now, so it is not competing with the document for
    /// room — it only has to leave enough of it showing to make clear the
    /// document is still there, and to leave somewhere to click to dismiss.
    public static let minimumUncoveredDocumentWidth: CGFloat = 240

    /// Clamps an explorer width to what the window can actually show.
    ///
    /// The lower bound wins over the upper one. In a window too narrow for
    /// both bounds to hold, an explorer at its minimum width that covers too
    /// much is better than one clamped to nothing at all.
    public static func explorerWidth(
        _ proposed: CGFloat,
        totalWidth: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let ceiling = max(
            minimum,
            min(maximum, totalWidth - minimumUncoveredDocumentWidth)
        )
        return min(max(proposed, minimum), ceiling)
    }

    /// Clamps a reading measure to what is left after the resize handle.
    public static func measureWidth(
        _ proposed: CGFloat,
        totalWidth: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        handleWidth: CGFloat
    ) -> CGFloat {
        let available = max(minimum, totalWidth - handleWidth)
        return min(max(proposed, minimum), min(maximum, available))
    }

    /// The leading inset that centers `measure` in `totalWidth`.
    ///
    /// Never negative: a measure wider than the window starts at its leading
    /// edge rather than off the side of it.
    public static func centeringInset(
        measure: CGFloat,
        totalWidth: CGFloat
    ) -> CGFloat {
        max(0, (totalWidth - measure) / 2)
    }
}
