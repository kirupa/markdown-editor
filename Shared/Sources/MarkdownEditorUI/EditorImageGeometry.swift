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
    /// much larger than the dot that advertises it — the same trade every
    /// resize handle on the platform makes. This gives a 33pt square at each
    /// corner, comfortably past the ~28pt that fingertip-sized guidance asks
    /// for, and it is capped on small pictures by `effectiveSlop`.
    public static let handleSlop: CGFloat = 12
    /// The narrowest an image may be dragged, in points.
    public static let minimumSide: CGFloat = 24

    /// How much room the overlay needs around the picture.
    ///
    /// Sized for the *target*, not the dot. The overlay clips to its own
    /// bounds, so an inset that only covers the drawn square silently trims
    /// the widened target back to the dot — the pointer would promise a resize
    /// at the outer edge and a click there would fall through to the text.
    /// Half the dot hangs outside the corner, plus the whole slop.
    public static var overlayInset: CGFloat { handleSide / 2 + handleSlop }

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
    ///
    /// Widened generously, because the 9pt dot is an advertisement rather than
    /// the target — asking somebody to land on it exactly is asking them to
    /// aim at something the size of a full stop.
    ///
    /// The widening is capped on a small picture. Four targets of a fixed size
    /// would meet in the middle of anything narrow, leaving no body to take
    /// hold of, and the picture could then be resized but never dragged. The
    /// cap keeps a third of each side clear whatever the picture's size.
    public static func handleHitRect(
        _ corner: EditorImageCorner,
        in imageFrame: CGRect
    ) -> CGRect {
        let slop = effectiveSlop(in: imageFrame)
        return handleRect(corner, in: imageFrame)
            .insetBy(dx: -slop, dy: -slop)
    }

    /// How far outside the drawn square this picture can afford to reach.
    static func effectiveSlop(in imageFrame: CGRect) -> CGFloat {
        // How far a target reaches inward from an edge: half the dot plus the
        // slop. Two of those must leave a clear third in the middle.
        let shortest = min(imageFrame.width, imageFrame.height)
        let roomInward = max(0, shortest / 3 - handleSide / 2)
        return max(0, min(handleSlop, roomInward))
    }

    /// Apple's minimum comfortable tap target, and the smallest a touch build
    /// should make any corner.
    ///
    /// A pointer build can use a small target because the pointer is visible
    /// and one pixel wide. A finger is neither: it covers roughly five times
    /// the drawn dot and hides what it is over, so a touch build has to grow
    /// the target rather than ask for precision nobody has.
    public static let touchTarget: CGFloat = 44

    /// The region a *finger* has to land in to take hold of `corner`.
    ///
    /// Capped exactly as the pointer version is, and for the same reason: four
    /// fixed targets meet in the middle of a small picture, leaving no body to
    /// take hold of, and a picture that can be resized but never moved is a
    /// worse fault than a target that is hard to hit.
    public static func touchHitRect(
        _ corner: EditorImageCorner,
        in imageFrame: CGRect
    ) -> CGRect {
        let drawn = handleRect(corner, in: imageFrame)
        let shortest = min(imageFrame.width, imageFrame.height)
        let roomInward = max(0, shortest / 3 - drawn.width / 2)
        let grow = min(max(0, (touchTarget - drawn.width) / 2), roomInward)
        return drawn.insetBy(dx: -grow, dy: -grow)
    }

    /// The corner a *finger* at `point` takes hold of, or nil for the text.
    public static func touchCorner(
        at point: CGPoint,
        in imageFrame: CGRect
    ) -> EditorImageCorner? {
        EditorImageCorner.allCases
            .filter { touchHitRect($0, in: imageFrame).contains(point) }
            .min {
                distanceSquared(from: point, to: handleRect($0, in: imageFrame))
                    < distanceSquared(from: point, to: handleRect($1, in: imageFrame))
            }
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
    ///
    /// `maximum` is the width of the page. Without it a drag can ask for more
    /// room than the layout has, and TextKit answers by *compressing the
    /// picture into the line it has* while the height carries on growing —
    /// measured: asking for 700, 800 and 852 points all drew at 642, taller
    /// each time. The picture is silently distorted, and nothing says so.
    public static func draggedWidth(
        from startFrame: CGRect,
        corner: EditorImageCorner,
        deltaX: CGFloat,
        deltaY: CGFloat,
        maximum: CGFloat = .greatestFiniteMagnitude
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
        let ceiling = max(minimumSide, maximum)
        return min(ceiling, max(minimumSide, startFrame.width + change))
    }
}
