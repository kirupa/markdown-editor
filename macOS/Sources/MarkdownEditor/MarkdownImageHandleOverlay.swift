import AppKit
import MarkdownEditorCore
import MarkdownEditorUI

/// The corner being dragged. The geometry is shared with iOS and tested there;
/// only the cursor is AppKit's.
typealias MarkdownImageCorner = EditorImageCorner

extension EditorImageCorner {
    @MainActor
    var cursor: NSCursor {
        // A corner handle should say which way it moves. macOS 15 finally
        // exposes the real window-frame cursors; before that AppKit's diagonal
        // ones were private, so the shape is drawn instead of borrowed.
        if #available(macOS 15.0, *) {
            switch self {
            case .topLeading:
                return .frameResize(position: .topLeft, directions: .all)
            case .topTrailing:
                return .frameResize(position: .topRight, directions: .all)
            case .bottomLeading:
                return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomTrailing:
                return .frameResize(position: .bottomRight, directions: .all)
            }
        }
        switch self {
        case .topLeading, .bottomTrailing:
            return DiagonalResizeCursor.northWestSouthEast
        case .topTrailing, .bottomLeading:
            return DiagonalResizeCursor.northEastSouthWest
        }
    }
}

/// The frame and four corner handles drawn over a selected image.
///
/// A sibling of the text, never a part of it. An image is a single character in
/// the document, and anything drawn *inside* the attachment would have to be
/// measured and laid out as text; a view over the top can be moved, resized and
/// removed without the document noticing.
///
/// `hitTest` claims only the handles themselves, so a click anywhere else lands
/// in the text view underneath exactly as it did before.
@MainActor
final class MarkdownImageHandleOverlay: NSView {
    /// The rect of the image being resized, in this view's coordinates.
    private(set) var imageFrame: NSRect = .zero

    /// Live drag: the size to draw at, before anything is written down.
    var onPreview: ((MarkdownImageTag.Size) -> Void)?
    /// Release: the size to write into the document, as one undoable edit.
    var onCommit: ((MarkdownImageTag.Size) -> Void)?

    private var naturalSize: MarkdownImageTag.Size?
    private var dragCorner: MarkdownImageCorner?
    private var dragStartFrame: NSRect = .zero
    private var dragStartPoint: NSPoint = .zero
    private var previewSize: MarkdownImageTag.Size?
    private var isPushingCursor = false

    private static let handleSide = EditorImageGeometry.handleSide

    override var isFlipped: Bool { true }
    /// The caret belongs in the text. Taking first responder would take it out.
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Show the frame around `rect`, or hide it when `rect` is nil.
    func show(around rect: NSRect?, naturalSize: MarkdownImageTag.Size?) {
        guard let rect, rect.width > 1, rect.height > 1 else {
            hide()
            return
        }
        self.naturalSize = naturalSize
        imageFrame = rect
        let inset = EditorImageGeometry.overlayInset
        frame = rect.insetBy(dx: -inset, dy: -inset)
        isHidden = false
        needsDisplay = true
        invalidateCursors()
    }

    func hide() {
        guard !isHidden || dragCorner != nil else { return }
        popCursorIfNeeded()
        dragCorner = nil
        previewSize = nil
        isHidden = true
        needsDisplay = true
        invalidateCursors()
    }

    /// The corner cursors move with the frame, and the window caches them.
    private func invalidateCursors() {
        window?.invalidateCursorRects(for: self)
    }

    var isShowing: Bool { !isHidden }

    // MARK: - Drawing

    private var frameInBounds: NSRect {
        NSRect(
            x: EditorImageGeometry.overlayInset,
            y: EditorImageGeometry.overlayInset,
            width: imageFrame.width,
            height: imageFrame.height
        )
    }

    private func handleRect(_ corner: MarkdownImageCorner) -> NSRect {
        EditorImageGeometry.handleRect(corner, in: frameInBounds)
    }

    /// The area a corner actually answers to.
    ///
    /// Every question about a corner — what the cursor is, whether a click
    /// starts a drag, whether the click belongs to the text underneath — is
    /// asked of this one rect, so the pointer can never say one thing and the
    /// click do another.
    private func handleHitRect(_ corner: MarkdownImageCorner) -> NSRect {
        EditorImageGeometry.handleHitRect(corner, in: frameInBounds)
    }

    private func corner(at point: NSPoint) -> MarkdownImageCorner? {
        EditorImageGeometry.corner(at: point, in: frameInBounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let outline = frameInBounds.insetBy(dx: -0.5, dy: -0.5)

        accent.setStroke()
        let border = NSBezierPath(rect: outline)
        border.lineWidth = 1
        border.stroke()

        for corner in MarkdownImageCorner.allCases {
            let rect = handleRect(corner)
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: 1.5,
                yRadius: 1.5
            )
            NSColor.white.setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: - Hit testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        guard corner(at: convert(point, from: superview)) != nil else {
            // Everything else belongs to the text underneath, including the
            // middle of the image: dragging that should still select text.
            return nil
        }
        return self
    }

    /// Every rect this view claims for the pointer, and the shape it shows.
    ///
    /// Separate from `resetCursorRects` so it can be read directly. AppKit
    /// keeps registered cursor rects to itself, so without this the only way
    /// to check what the pointer does is to move the real mouse across a real
    /// screen — which needs the app frontmost and fights whoever is using the
    /// machine.
    func cursorRects() -> [(rect: NSRect, cursor: NSCursor)] {
        guard !isHidden else { return [] }
        return MarkdownImageCorner.allCases.map { (handleHitRect($0), $0.cursor) }
    }

    override func resetCursorRects() {
        for entry in cursorRects() {
            addCursorRect(entry.rect, cursor: entry.cursor)
        }
    }

    // MARK: - Dragging

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard let corner = corner(at: local) else { return }
        beginDrag(at: corner, from: event.locationInWindow)
    }

    /// Start a resize gesture. The one place a cursor is pushed.
    private func beginDrag(at corner: EditorImageCorner, from point: NSPoint) {
        dragCorner = corner
        // Hold the matching cursor for the whole gesture. Without this the
        // pointer reverts to whatever is under it the moment the drag carries
        // it off the handle, which is immediately.
        corner.cursor.push()
        isPushingCursor = true
        dragStartFrame = imageFrame
        dragStartPoint = point
        previewSize = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let corner = dragCorner else { return }
        let deltaX = event.locationInWindow.x - dragStartPoint.x
        // The window is not flipped even though this view is, so a drag *up*
        // the screen raises y here and lowers it in the text.
        let deltaY = dragStartPoint.y - event.locationInWindow.y

        let width = EditorImageGeometry.draggedWidth(
            from: dragStartFrame,
            corner: corner,
            deltaX: deltaX,
            deltaY: deltaY
        )
        let size = MarkdownImageTag.proportionalSize(
            MarkdownImageTag.Size(width: Int(width.rounded()), height: nil),
            natural: naturalSize ?? measuredNaturalSize(),
            edited: .width
        )
        previewSize = size
        onPreview?(size)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            popCursorIfNeeded()
            dragCorner = nil
            previewSize = nil
        }
        guard dragCorner != nil, let size = previewSize else { return }
        // One edit for the whole drag. Committing per step would bury whatever
        // came before it under a hundred identical undo entries.
        onCommit?(size)
    }

    /// Whether a corner is being dragged right now.
    var isDragging: Bool { dragCorner != nil }

    /// Start a drag without a mouse, for `check-image-layout`. Goes through the
    /// real entry point so the harness cannot drift from what a click does.
    func beginDragForChecking(at corner: EditorImageCorner) {
        beginDrag(at: corner, from: .zero)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A drag can end by the view going away — closing the window with the
        // mouse down, or SwiftUI rebuilding the representable — and then no
        // `mouseUp` ever arrives. `NSCursor`'s stack is process-wide, so the
        // diagonal arrow would be left on it for every other app to inherit.
        if newWindow == nil {
            popCursorIfNeeded()
            dragCorner = nil
            previewSize = nil
        }
    }

    deinit {
        // Not `popCursorIfNeeded`: `deinit` is nonisolated, and by here nothing
        // else can pop this. The flag is only ever true between a `mouseDown`
        // and its matching exit.
        if isPushingCursor {
            NSCursor.pop()
        }
    }

    private func popCursorIfNeeded() {
        guard isPushingCursor else { return }
        isPushingCursor = false
        NSCursor.pop()
    }

    /// The shape currently on screen, for an image whose own pixels could not
    /// be measured. Preserving what is drawn is better than refusing to resize.
    private func measuredNaturalSize() -> MarkdownImageTag.Size? {
        guard dragStartFrame.width > 0, dragStartFrame.height > 0 else {
            return nil
        }
        return MarkdownImageTag.Size(
            width: Int(dragStartFrame.width.rounded()),
            height: Int(dragStartFrame.height.rounded())
        )
    }
}
