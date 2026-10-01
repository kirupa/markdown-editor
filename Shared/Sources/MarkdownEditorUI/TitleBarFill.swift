import CoreGraphics

/// What a double-click on a document window's title bar does: fill the
/// screen, and on the next double-click put the window back.
///
/// This is not Zoom. Zoom asks the window for the best size for its content,
/// and this window answers with the document plus its comments. A double-click
/// asks for *all* the room there is. macOS offers the two as separate choices
/// under "Double-click a window's title bar to", and this is its "Fill".
///
/// Kept apart from the window so the rules can be checked without a screen.
/// They all decide which frame counts as "filled", and a wrong answer shows up
/// the same way either way: the second double-click fills again instead of
/// going back.
public struct TitleBarFill: Equatable, Sendable {
    /// How far apart two frames may be and still count as the same frame.
    ///
    /// The window server rounds a frame to the display's pixels, so a window
    /// told to fill a fractional rect settles a fraction away from it.
    public static let tolerance: CGFloat = 2

    /// Where the window was before it last filled the screen.
    public private(set) var restoreFrame: CGRect?
    /// Where filling actually left it.
    public private(set) var filledFrame: CGRect?

    public init() {}

    /// The frame a double-click sends a window at `frame` to.
    ///
    /// `available` is the screen's visible frame: everything but the menu bar
    /// and the Dock. `fallbackSize` is where a window that already fills the
    /// screen goes when there is no earlier frame to return to — one restored
    /// at full size after a relaunch, or one dragged out to the edges by hand.
    /// Without it the gesture would do nothing to exactly the window it is
    /// most wanted on.
    public mutating func toggle(
        from frame: CGRect,
        available: CGRect,
        fallbackSize: CGSize
    ) -> CGRect {
        if let restoreFrame, let filledFrame,
           Self.same(frame, filledFrame) || Self.same(frame, available) {
            self = TitleBarFill()
            return Self.place(restoreFrame, in: available)
        }
        // Moved or resized since it filled, or never filled: either way the
        // earlier frame no longer describes where it would be going back from.
        if Self.same(frame, available) {
            self = TitleBarFill()
            return Self.centre(fallbackSize, in: available)
        }
        restoreFrame = frame
        filledFrame = available
        return available
    }

    /// Records where the window actually came to rest after filling.
    ///
    /// Ignored when it did not move at all, so a frame read before the resize
    /// took effect cannot turn the earlier frame into the "filled" one.
    public mutating func settle(at frame: CGRect) {
        guard let restoreFrame, !Self.same(frame, restoreFrame) else { return }
        filledFrame = frame
    }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    /// `frame` exactly as it was, unless it no longer fits on this screen.
    ///
    /// A display can change while a window fills it — a smaller one plugged
    /// in, a resolution changed — and going back to a frame larger than the
    /// screen, or off it entirely, is not going back to anything usable.
    static func place(_ frame: CGRect, in available: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, available.width),
            height: min(frame.height, available.height)
        )
        if size == frame.size, available.intersects(frame) { return frame }
        return CGRect(
            x: min(max(frame.minX, available.minX), available.maxX - size.width),
            y: min(max(frame.minY, available.minY), available.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    static func centre(_ size: CGSize, in available: CGRect) -> CGRect {
        let width = min(size.width, available.width)
        let height = min(size.height, available.height)
        return CGRect(
            x: available.midX - width / 2,
            y: available.midY - height / 2,
            width: width,
            height: height
        )
    }
}
