import AppKit

/// The line shown while a picture is being dragged, marking where it will land.
///
/// A picture dropped into a document goes *between* two lines, not between two
/// characters, so this is drawn as a rule across the column rather than as a
/// text caret. The first version used a caret, and it invited exactly the drop
/// it looked like it was promising: into the middle of a word.
///
/// Purely decorative: it never takes a click.
@MainActor
final class MarkdownImageDropLine: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Draw the rule across `width` at `y`, or nothing when `y` is nil.
    func show(atY y: CGFloat?, from x: CGFloat, width: CGFloat) {
        guard let y, width > 1 else {
            guard !isHidden else { return }
            isHidden = true
            return
        }
        let wanted = NSRect(x: x, y: y - Self.thickness / 2,
                            width: width, height: Self.thickness)
        if isHidden || wanted != frame {
            frame = wanted
            isHidden = false
            needsDisplay = true
        }
    }

    /// Thick enough to read as a deliberate mark at a glance while the pointer
    /// is moving, which a hairline is not.
    private static let thickness: CGFloat = 3

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.thickness / 2,
                     yRadius: Self.thickness / 2).fill()
    }
}

/// A translucent copy of the picture that follows the pointer during a move.
///
/// Without it the only thing that moves is a caret somewhere else on the page,
/// and the gesture reads as though nothing has been picked up.
@MainActor
final class MarkdownImageDragGhost: NSView {
    private var image: NSImage?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        alphaValue = 0.45
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Carry `image` at `size`, centred on `point`.
    func show(_ image: NSImage?, size: NSSize, centredOn point: NSPoint) {
        guard let image, size.width > 1, size.height > 1 else {
            hide()
            return
        }
        self.image = image
        frame = NSRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        guard !isHidden else { return }
        isHidden = true
        image = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
}
