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

    /// An offset clamped into what this document can actually show, used when
    /// restoring a remembered position after the document has changed height.
    public func clampedOffset(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, 0), maximumOffset)
    }

    private static let tolerance: CGFloat = 0.5
}
