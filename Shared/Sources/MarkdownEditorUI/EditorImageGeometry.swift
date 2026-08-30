import CoreGraphics

/// Which corner of a selected image is being pointed at, and which way each of
/// its axes grows.
///
/// One expression covers all four: the top-left handle grows the image when it
/// moves left and up, the bottom-right when it moves right and down.
public enum EditorImageCorner: CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    /// -1 when moving in the positive direction on this axis *shrinks* the
    /// image, +1 when it grows it.
    public var horizontalGrowth: CGFloat {
        switch self {
        case .topLeading, .bottomLeading: return -1
        case .topTrailing, .bottomTrailing: return 1
        }
    }

    /// Expressed for a flipped coordinate space, where "down the screen" is +y.
    /// Both editors draw text in one, and so does the overlay above it.
    public var verticalGrowth: CGFloat {
        switch self {
        case .topLeading, .topTrailing: return -1
        case .bottomLeading, .bottomTrailing: return 1
        }
    }

    public func position(in rect: CGRect) -> CGPoint {
        CGPoint(
            x: horizontalGrowth < 0 ? rect.minX : rect.maxX,
            y: verticalGrowth < 0 ? rect.minY : rect.maxY
        )
    }
}

/// Where a selected image and its resize handles are, in view coordinates.
///
/// This is arithmetic, not drawing, so it lives here where it can be tested
/// rather than inside an `NSView` where it cannot. Every one of these numbers
/// decides something the pointer does — what shape the cursor takes, whether a
/// click starts a resize, whether it falls through to the text — so the same
/// function has to answer all of those questions or they drift apart.
public enum EditorImageGeometry {
    /// The side of the square drawn at each corner.
    public static let handleSide: CGFloat = 9
    /// How far outside that square a corner still answers.
    ///
    /// A 9pt target is a hard thing to hit, so the region that responds is
    /// larger than the dot that advertises it — the same trade every resize
    /// handle on the platform makes.
    public static let handleSlop: CGFloat = 4
    /// The narrowest an image may be dragged, in points.
    public static let minimumSide: CGFloat = 24

    /// How much room the overlay needs around the picture to draw its corners.
    public static var overlayInset: CGFloat { handleSide }

    /// Where an image attachment is actually drawn.
    ///
    /// The obvious answer, `NSLayoutManager.boundingRect(forGlyphRange:in:)`,
    /// is the glyph's *line* box: as tall as the tallest thing on that line and
    /// carrying the paragraph's line spacing. Using it accepts clicks in the
    /// blank strip above and below the picture and draws the selection frame
    /// around that empty space.
    ///
    /// `glyphLocation` is where the layout manager draws the attachment from,
    /// and it is *not* the text baseline: it is the picture's own bottom-left
    /// corner, with `NSTextAttachment.bounds.origin` already folded in. So the
    /// offset must not be applied again here, and this takes only the size to
    /// make that impossible. Measured rather than assumed — `check-image-handles`
    /// renders attachments offset by 0, -4, +12 and -20 points and finds the
    /// drawn pixels in the same place each time. The renderer really does set a
    /// negative offset, so this is not hypothetical: it was a 4pt error that put
    /// every handle below the corner it was holding.
    public static func attachmentRect(
        lineFragment: CGRect,
        glyphLocation: CGPoint,
        attachmentSize: CGSize,
        containerOrigin: CGPoint
    ) -> CGRect {
        CGRect(
            x: lineFragment.minX + glyphLocation.x + containerOrigin.x,
            y: lineFragment.minY + glyphLocation.y - attachmentSize.height
                + containerOrigin.y,
            width: attachmentSize.width,
            height: attachmentSize.height
        )
    }

    /// The square drawn at `corner` of an image occupying `imageFrame`.
    public static func handleRect(
        _ corner: EditorImageCorner,
        in imageFrame: CGRect
    ) -> CGRect {
        let center = corner.position(in: imageFrame)
        return CGRect(
            x: center.x - handleSide / 2,
            y: center.y - handleSide / 2,
            width: handleSide,
            height: handleSide
        )
    }

    /// The region that `corner` answers to: the drawn square, widened.
    public static func handleHitRect(
        _ corner: EditorImageCorner,
        in imageFrame: CGRect
    ) -> CGRect {
        handleRect(corner, in: imageFrame)
            .insetBy(dx: -handleSlop, dy: -handleSlop)
    }

    /// The corner under `point`, or nil when the point belongs to the text.
    ///
    /// Nearest wins. On a picture small enough that two widened targets
    /// overlap, the overlap has to go to the corner actually being pointed at,
    /// or one of them becomes unreachable.
    public static func corner(
        at point: CGPoint,
        in imageFrame: CGRect
    ) -> EditorImageCorner? {
        EditorImageCorner.allCases
            .filter { handleHitRect($0, in: imageFrame).contains(point) }
            .min {
                distanceSquared(from: point, to: handleRect($0, in: imageFrame))
                    < distanceSquared(
                        from: point,
                        to: handleRect($1, in: imageFrame)
                    )
            }
    }

    private static func distanceSquared(
        from point: CGPoint,
        to rect: CGRect
    ) -> CGFloat {
        let dx = point.x - rect.midX
        let dy = point.y - rect.midY
        return dx * dx + dy * dy
    }

    /// The width a drag of `deltaX`/`deltaY` from `corner` asks for.
    ///
    /// Both axes vote and the larger movement wins, measured in width so the
    /// comparison is like for like, so a diagonal drag does what it looks like
    /// it should whichever way it leans. `deltaY` is in the flipped space the
    /// image is drawn in: positive is down the screen.
    public static func draggedWidth(
        from startFrame: CGRect,
        corner: EditorImageCorner,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> CGFloat {
        guard startFrame.width > 0 else { return minimumSide }
        let ratio = startFrame.height / startFrame.width
        let widthChange = deltaX * corner.horizontalGrowth
        let heightChange = deltaY * corner.verticalGrowth
        let heightChangeAsWidth = ratio > 0
            ? heightChange / ratio
            : heightChange
        let change = abs(widthChange) >= abs(heightChangeAsWidth)
            ? widthChange
            : heightChangeAsWidth
        return max(minimumSide, startFrame.width + change)
    }
}
