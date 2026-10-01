import CoreGraphics

/// The scroll geometry of one editor pane, reduced to plain numbers.
///
/// Both panes re-style by replacing the whole text storage, and a scroll view
/// asked about itself in the middle of that reports figures that have not
/// settled: the viewport can still have no height, and the document height is
/// whatever partial layout has produced so far rather than the real total.
///
/// Deriving a scroll position from those figures is what made the document
/// jump. A pane sitting 20pt down a 29629pt document reported itself as 20/114
/// — about 17% of the way in, because only 114pt had been laid out — and
/// applying 17% to the true height threw the reader 5198pt down the page. The
/// reveal-the-caret step then dragged everything back, which is the "jump to
/// the bottom and back" a writer sees while typing.
///
/// Keeping the arithmetic here, away from AppKit, means those rules can be
/// tested directly with the numbers that actually occurred.
public struct EditorScrollGeometry: Equatable, Sendable {
    /// The full height of the laid-out document.
    public var documentHeight: CGFloat
    /// The height of the visible window onto that document.
    public var viewportHeight: CGFloat
    /// How far down the document the viewport currently sits.
    public var offset: CGFloat

    public init(
        documentHeight: CGFloat,
        viewportHeight: CGFloat,
        offset: CGFloat
    ) {
        self.documentHeight = documentHeight
        self.viewportHeight = viewportHeight
        self.offset = offset
    }

    /// The furthest down the document the viewport can be scrolled. Zero when
    /// the document is no taller than the viewport, which is a legitimate
    /// state, not an unresolved one.
    public var maximumOffset: CGFloat {
        max(0, documentHeight - viewportHeight)
    }

    /// Whether these figures describe a pane that has actually been laid out.
    ///
    /// A viewport with no height has not been through a layout pass. A
    /// document with no height has no text laid out yet. An offset beyond
    /// what the document allows means the two figures were sampled at
    /// different moments — during a re-style the offset survives from the old
    /// document while the height reflects only the part of the new one that
    /// has been laid out so far.
    public var isResolved: Bool {
        guard viewportHeight > 0, documentHeight > 0 else {
            return false
        }
        return offset <= maximumOffset + Self.tolerance
    }

    /// Where the viewport sits as a fraction of its travel, or `nil` when the
    /// figures cannot support the question.
    ///
    /// `nil` is deliberate. The previous version returned `0` for an
    /// unresolved pane, which is indistinguishable from a pane genuinely
    /// parked at the top, so callers could not tell a real position from a
    /// meaningless one and published the meaningless ones.
    public var normalizedPosition: CGFloat? {
        guard isResolved else {
            return nil
        }
        guard maximumOffset > 0 else {
            return 0
        }
        return min(max(offset / maximumOffset, 0), 1)
    }

    /// The offset a fraction of the way down this document, or `nil` when the
    /// pane is not laid out well enough to place it.
    public func offset(forNormalizedPosition position: CGFloat) -> CGFloat? {
        guard viewportHeight > 0, documentHeight > 0 else {
            return nil
        }
        return min(max(position, 0), 1) * maximumOffset
    }

    /// Whether moving to `target` is a large enough change to be worth doing.
    /// Sub-point corrections are churn that can feed back into the pane that
    /// asked for them.
    public func shouldMove(to target: CGFloat) -> Bool {
        abs(offset - target) > Self.tolerance
    }

    /// Where to park the viewport to show a passage somebody asked to be taken
    /// to.
    ///
    /// Deliberately not "scroll it into view". The platform's own reveal does
    /// the *smallest* scroll that makes a rectangle visible, which lands a
    /// passage below the fold hard against the bottom edge of the window, with
    /// the sentence it is about half under the scroller and nothing after it
    /// to read. That is technically visible and no use: the reader clicked a
    /// comment to look at a sentence in its paragraph.
    ///
    /// So the passage is placed a third of the way down instead, which leaves
    /// what comes before it for context and two-thirds of the window for what
    /// comes after. Three cases fall out of the clamp rather than needing
    /// rules of their own: a passage near the top of the document cannot be
    /// pushed down and simply stays where it is, one near the end stops at the
    /// document's last screenful, and a document shorter than the window does
    /// not move at all.
    ///
    /// A passage taller than the window is the one case that is not a clamp. It
    /// cannot be framed, so its *start* is put at the top: a reader taken to a
    /// long quotation wants to begin at its first word, not a third of the way
    /// into it.
    public func offset(
        toReveal passage: (minY: CGFloat, height: CGFloat),
        placedAt fraction: CGFloat = Self.revealFraction
    ) -> CGFloat {
        guard viewportHeight > 0 else {
            return offset
        }
        let margin = passage.height >= viewportHeight
            ? 0
            : min(max(fraction, 0), 1) * viewportHeight
        return clampedOffset(passage.minY - margin)
    }

    /// Whether a passage is already framed well enough that taking the reader
    /// there would only shuffle the page under them.
    ///
    /// This is what keeps the reveal from firing on a click in the *text*. A
    /// click on a shaded passage raises its note, and the reader is by
    /// definition already looking at the passage — moving the page under the
    /// pointer that just landed on it is the rudest thing the feature could
    /// do.
    ///
    /// Bare visibility is the wrong test, though: a passage sitting in the
    /// last few points of the window is visible and is exactly what the reveal
    /// exists to fix. It has to be comfortably inside — with `margin` of air
    /// above and below — before doing nothing is the better answer. A passage
    /// taller than the window can never be framed whole, so for that one it is
    /// the first line that has to be comfortable.
    public func isComfortablyVisible(
        _ passage: (minY: CGFloat, height: CGFloat),
        margin: CGFloat = 24
    ) -> Bool {
        guard viewportHeight > 2 * margin else {
            return false
        }
        let top = offset + margin
        let bottom = offset + viewportHeight - margin
        let end = passage.height >= viewportHeight
            ? passage.minY
            : passage.minY + passage.height
        return passage.minY >= top && end <= bottom
    }

    /// An offset clamped into what this document can actually show, used when
    /// restoring a remembered position after the document has changed height.
    public func clampedOffset(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, 0), maximumOffset)
    }

    /// How far down the window a revealed passage is placed.
    public static let revealFraction: CGFloat = 1.0 / 3.0

    private static let tolerance: CGFloat = 0.5
}
