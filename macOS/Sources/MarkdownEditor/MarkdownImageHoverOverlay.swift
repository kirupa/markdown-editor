import AppKit

/// A faint outline around the picture the pointer is over.
///
/// The arrow already says "this is an object rather than somewhere to type",
/// but it says it about the whole picture area without saying where that area
/// ends. The outline answers that, and it is what makes a picture look
/// draggable before anything has been clicked.
///
/// Deliberately fainter than the selection frame `MarkdownImageHandleOverlay`
/// draws, and hidden entirely for the selected picture, so hovering the
/// selection does not draw two frames around one picture.
///
/// Purely decorative: `hitTest` returns nil for every point, so it never takes
/// a click away from the picture or the text.
@MainActor
final class MarkdownImageHoverOverlay: NSView {
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

    /// Outline `rect`, or show nothing when it is nil.
    func show(around rect: NSRect?) {
        guard let rect, rect.width > 1, rect.height > 1 else {
            guard !isHidden else { return }
            isHidden = true
            return
        }
        let wanted = rect.insetBy(dx: -Self.inset, dy: -Self.inset)
        guard isHidden || wanted != frame else { return }
        frame = wanted
        isHidden = false
        needsDisplay = true
    }

    /// Far enough out to read as a frame around the picture rather than a
    /// border drawn on it, and inside the selection frame so the two do not
    /// sit on the same pixels.
    private static let inset: CGFloat = 2

    override func draw(_ dirtyRect: NSRect) {
        let line: CGFloat = 1
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
            xRadius: 3,
            yRadius: 3
        )
        path.lineWidth = line
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setStroke()
        path.stroke()
    }
}
