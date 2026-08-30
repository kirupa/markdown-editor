import AppKit

/// The diagonal double-headed arrows AppKit did not expose until macOS 15.
///
/// Drawn rather than borrowed: the private `_windowResizeNorthWestSouthEast`
/// cursors do the job on every system this app runs on, but shipping a call to
/// a private selector is not worth a working cursor. Black with a white
/// outline, like every system cursor, so it stays legible over a photograph.
@MainActor
enum DiagonalResizeCursor {
    static let northWestSouthEast = make(leaningRight: false)
    static let northEastSouthWest = make(leaningRight: true)

    private static func make(leaningRight: Bool) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        let inset: CGFloat = 5
        let low = NSPoint(x: inset, y: inset)
        let high = NSPoint(x: side - inset, y: side - inset)
        // The two ends of the shaft. Flipping one axis turns "\" into "/".
        let start = leaningRight ? NSPoint(x: low.x, y: high.y) : low
        let end = leaningRight ? NSPoint(x: high.x, y: low.y) : high

        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        appendArrowHead(to: path, at: start, pointingAwayFrom: end)
        appendArrowHead(to: path, at: end, pointingAwayFrom: start)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // The outline is the same path stroked wider underneath, so the black
        // shape keeps a white edge on every side without drawing it twice.
        NSColor.white.setStroke()
        path.lineWidth = 4.5
        path.stroke()
        NSColor.black.setStroke()
        path.lineWidth = 2
        path.stroke()

        image.unlockFocus()
        return NSCursor(
            image: image,
            hotSpot: NSPoint(x: side / 2, y: side / 2)
        )
    }

    private static func appendArrowHead(
        to path: NSBezierPath,
        at tip: NSPoint,
        pointingAwayFrom other: NSPoint
    ) {
        let dx = tip.x - other.x
        let dy = tip.y - other.y
        let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
        let unitX = dx / length
        let unitY = dy / length
        let head: CGFloat = 6.5
        // The two barbs are the shaft direction turned back on itself either
        // way, so they sit against the tip whichever way the shaft points.
        for angle in [CGFloat.pi * 0.75, -CGFloat.pi * 0.75] {
            let rotatedX = unitX * cos(angle) - unitY * sin(angle)
            let rotatedY = unitX * sin(angle) + unitY * cos(angle)
            path.move(to: tip)
            path.line(
                to: NSPoint(
                    x: tip.x + rotatedX * head,
                    y: tip.y + rotatedY * head
                )
            )
        }
    }
}
