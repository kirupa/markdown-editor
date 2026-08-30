import AppKit

/// The caret shown while a picture is being dragged, marking where it will
/// land if it is dropped now.
///
/// This is the same promise the text caret makes — the picture is going to be
/// inserted *here*, between these two characters — so it is drawn the same way
/// rather than as a box or a highlight, which would suggest replacing
/// something instead of moving between.
///
/// Purely decorative: it never takes a click.
@MainActor
final class MarkdownImageDropCaret: NSView {
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

    /// Show the caret filling `rect`, or nothing when it is nil.
    func show(at rect: NSRect?) {
        guard let rect, rect.height > 1 else {
            guard !isHidden else { return }
            isHidden = true
            return
        }
        let wanted = NSRect(x: rect.minX - Self.width / 2, y: rect.minY,
                            width: Self.width, height: rect.height)
        if isHidden || wanted != frame {
            frame = wanted
            isHidden = false
            needsDisplay = true
        }
    }

    /// Wider than the text caret. This one is being aimed at while the pointer
    /// is moving, so it has to be findable rather than discreet.
    private static let width: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
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
