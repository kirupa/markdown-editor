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

    // MARK: - The page and the column inside it

    /// How far a picture may reach past the text column, on each side.
    ///
    /// The page is wider than the column the text is set in, and that margin
    /// is not dead space: a picture may spread into it, symmetrically, so an
    /// illustration can be given more room than a line of prose should have.
    /// Text never uses it, because a longer line is a worse line to read.
    public static let maximumImageBleed: CGFloat = 100

    /// How much margin there is each side of a column of `columnWidth` set in
    /// `availableWidth`, up to `maximumImageBleed`.
    ///
    /// Whatever room is left over. A window — or a phone — with nothing to
    /// spare gets no bleed at all rather than a picture running off the side,
    /// and the rest of the model goes on working with a bleed of zero: the
    /// page and the column are then the same thing.
    public static func imageBleed(
        around columnWidth: CGFloat,
        within availableWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth > columnWidth else { return 0 }
        return min(maximumImageBleed, (availableWidth - columnWidth) / 2)
    }

    /// Where the document's leading edge goes when a margin rail is open.
    ///
    /// Comments belong beside the passage they are about, so the rail sits in
    /// the document's right margin rather than against the window's edge —
    /// pinned to the edge it is a panel that happens to contain comments, and
    /// on a wide screen the note ends up a hand's width from the sentence.
    ///
    /// The document does not move while the margin can hold the rail, which is
    /// the usual case and the one that matters: opening comments should not
    /// reflow what you are reading. Only when the margin is too narrow does the
    /// document give way, and then by the least it can.
    public static func documentInsetWithRail(
        documentWidth: CGFloat,
        railWidth: CGFloat,
        totalWidth: CGFloat
    ) -> CGFloat {
        let centred = max(0, (totalWidth - documentWidth) / 2)
        guard centred < railWidth else { return centred }
        return max(0, totalWidth - documentWidth - railWidth)
    }

    /// The widest a picture may be drawn: the full page.
    public static func maximumImageWidth(
        measure: CGFloat,
        bleed: CGFloat
    ) -> CGFloat {
        max(1, measure) + 2 * max(0, bleed)
    }

    /// How far the paragraph holding a picture of `imageWidth` is indented.
    ///
    /// A picture that fits the column is indented like the text around it, so
    /// it lines up with it. Past that the indent gives way at the same rate on
    /// both sides, so the picture spreads into the margins symmetrically and
    /// stays centred on the column it came from. The two rules meet exactly at
    /// the column's width, so there is no jump as a picture is dragged past it.
    public static func imageParagraphIndent(
        imageWidth: CGFloat,
        measure: CGFloat,
        bleed: CGFloat
    ) -> CGFloat {
        let bleed = max(0, bleed)
        let page = maximumImageWidth(measure: measure, bleed: bleed)
        return min(bleed, max(0, (page - imageWidth) / 2))
    }
}

/// The width of the text column, and how far a picture may reach past it.
///
/// Passed to the styler so it can indent prose to the column while letting a
/// picture spread wider. Both numbers are in points, and `bleed` may be zero —
/// on a phone there is no room for a margin, so the page *is* the column.
public struct MarkdownPageMetrics: Equatable, Sendable {
    /// The width prose is set in.
    public let measure: CGFloat
    /// How far a picture may reach past it, on each side.
    public let bleed: CGFloat

    public init(measure: CGFloat, bleed: CGFloat) {
        self.measure = max(1, measure)
        self.bleed = max(0, bleed)
    }

    /// The widest a picture may be drawn.
    public var maximumImageWidth: CGFloat {
        EditorPaneGeometry.maximumImageWidth(measure: measure, bleed: bleed)
    }

    /// How far the paragraph holding a picture of `imageWidth` is indented.
    public func imageParagraphIndent(imageWidth: CGFloat) -> CGFloat {
        EditorPaneGeometry.imageParagraphIndent(
            imageWidth: imageWidth,
            measure: measure,
            bleed: bleed
        )
    }
}
