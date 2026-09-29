import CoreGraphics

/// One line's share of a text selection, as it is shaded: a rounded bar
/// fitted to the selected words on that line.
///
/// Where a selection carries on past the end of a line, the bar runs a little
/// way beyond the last word and fades out; the next line's bar fades in from a
/// little before its first word. So a selection broken across lines still
/// reads as one thing, rather than as blocks that stop dead at the margins —
/// and the ends that really are ends, where the selection starts and stops,
/// are the only ones drawn with a hard, rounded edge. Those stand exactly on
/// the caret positions either side of the selection, so a bar never reaches
/// into a letter that is not selected.
///
/// Kept apart from the text views so the shape can be checked without laying
/// out any text. The views measure; this decides what to draw.
public struct SelectionHighlightSegment: Equatable, Sendable {
    /// A point along the bar, left to right, and how strongly it is shaded.
    public struct Stop: Equatable, Sendable {
        /// 0 at the bar's left edge, 1 at its right.
        public var location: CGFloat
        /// 0 is untinted, 1 is the full selection tint.
        public var opacity: CGFloat
    }

    /// The whole bar, fades included.
    public var rect: CGRect
    public var cornerRadius: CGFloat
    /// How far the left end fades in over. Zero where the selection starts
    /// on this line.
    public var fadeIn: CGFloat
    /// How far the right end fades out over. Zero where the selection stops
    /// on this line.
    public var fadeOut: CGFloat

    /// The bar for the selected run from `start` to `end` on a line whose
    /// text stands from `top` to `bottom`.
    ///
    /// `continuesFromPreviousLine` when the selection began on an earlier
    /// line, and `continuesOntoNextLine` when it runs on past this one —
    /// including when the line's own break is selected, which is the same
    /// thing seen from the other side.
    ///
    /// `start` and `end` are caret positions, and a hard end is drawn on its
    /// caret, with no padding: the letter beside it is not selected. A run
    /// with no width — an empty line inside a selection, or a selection that
    /// starts on a line's break — is still given a little, so it shows; a
    /// narrow one, a single "i", is not widened into its neighbours.
    public static func line(
        from start: CGFloat,
        to end: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        continuesFromPreviousLine: Bool,
        continuesOntoNextLine: Bool
    ) -> SelectionHighlightSegment {
        let height = max(0, bottom - top)
        let left = min(start, end)
        let measured = max(start, end)
        let right = measured - left < noWidth
            ? left + emptyRunWidth(forHeight: height)
            : measured
        let fade = fadeLength(forHeight: height)
        let fadeIn = continuesFromPreviousLine ? fade : 0
        let fadeOut = continuesOntoNextLine ? fade : 0
        let minX = left - fadeIn
        let maxX = right + fadeOut
        let rect = CGRect(
            x: minX,
            y: top,
            width: maxX - minX,
            height: height
        )
        return SelectionHighlightSegment(
            rect: rect,
            cornerRadius: min(
                cornerRadius(forHeight: height),
                rect.width / 2
            ),
            fadeIn: fadeIn,
            fadeOut: fadeOut
        )
    }

    /// How rounded a bar `height` tall is: a little over a fifth of its
    /// height, so a line of body text and a line of a heading look like the
    /// same object — softened, but still a bar — and never more than 6 points,
    /// however tall the line.
    public static func cornerRadius(forHeight height: CGFloat) -> CGFloat {
        min(max(0, height) * 0.22, 6)
    }

    /// How far a bar `height` tall runs past a line's end as it fades: most
    /// of a line's height, so it reads as the selection carrying on without
    /// reaching far into the margin.
    public static func fadeLength(forHeight height: CGFloat) -> CGFloat {
        min(max(max(0, height) * 0.75, 10), 24)
    }

    /// How wide a run with no width of its own is drawn — an empty line in a
    /// selection, or a selected break: about a space, so it still shows.
    public static func emptyRunWidth(forHeight height: CGFloat) -> CGFloat {
        max(4, max(0, height) * 0.3)
    }

    /// Narrower than this, a run is a caret, not ink: nothing to hug.
    private static let noWidth: CGFloat = 0.5

    /// How strongly the bar is shaded along its length, for a left-to-right
    /// gradient: full where it is not fading, easing to nothing across a
    /// fade. Always starts at 0 and ends at 1.
    public var stops: [Stop] {
        let width = rect.width
        guard width > 0 else {
            return [Stop(location: 0, opacity: 1), Stop(location: 1, opacity: 1)]
        }
        // Smoothstep, sampled: a straight ramp shows a visible crease where it
        // meets the flat part of the bar.
        let ease: [(t: CGFloat, opacity: CGFloat)] = [
            (0, 0), (0.25, 0.156), (0.5, 0.5), (0.75, 0.844), (1, 1)
        ]
        var stops: [Stop] = []
        if fadeIn > 0 {
            for point in ease {
                stops.append(
                    Stop(location: point.t * fadeIn / width, opacity: point.opacity)
                )
            }
        } else {
            stops.append(Stop(location: 0, opacity: 1))
        }
        if fadeOut > 0 {
            for point in ease.reversed() {
                stops.append(
                    Stop(
                        location: 1 - point.t * fadeOut / width,
                        opacity: point.opacity
                    )
                )
            }
        } else {
            stops.append(Stop(location: 1, opacity: 1))
        }
        return stops
    }
}
