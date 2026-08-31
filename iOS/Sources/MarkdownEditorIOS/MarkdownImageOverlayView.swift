import MarkdownEditorCore
import MarkdownEditorUI
import UIKit

/// Selecting a picture, resizing it by dragging a corner, and moving it to
/// somewhere else in the document.
///
/// The same three gestures the macOS build has, expressed the way iOS does
/// them. The differences are deliberate rather than incidental:
///
///  - There is no pointer, so nothing can be communicated by a cursor shape.
///    The frame and its handles have to be visible as soon as a picture is
///    touched, because they are the only thing saying it can be resized.
///  - The handles are sized for a fingertip. `EditorImageGeometry.handleSlop`
///    is tuned for a mouse; here the target is grown to `touchTarget`, which is
///    the platform's minimum comfortable tap size.
///  - A drag that moves the picture starts from a long press, not from travel
///    alone. A short drag on a touch screen is how the document is scrolled, so
///    taking it for a move would make the document impossible to read.
///
/// Everything below the gestures is shared: the geometry comes from
/// `EditorImageGeometry` and the document edit from `MarkdownFormatting`, so a
/// picture resized or moved on a phone lands exactly where it lands on a Mac.
@MainActor
final class MarkdownImageOverlayView: UIView {
    /// Called with the image's source range and the size to write.
    var onResize: ((NSRange, MarkdownImageTag.Size) -> Void)?
    /// Called with the image's source range and where to move it to.
    var onMove: ((NSRange, Int) -> Void)?
    /// The natural pixel size of the image occupying a source range.
    var naturalSizeForImage: ((NSRange) -> MarkdownImageTag.Size?)?


    private weak var textView: UITextView?
    private var selection: (range: NSRange, rect: CGRect)?
    private var resize: ResizeDrag?
    private var move: MoveDrag?

    private let frameLayer = CAShapeLayer()
    private var handleLayers: [EditorImageCorner: CAShapeLayer] = [:]
    private let dropLine = UIView()
    private let ghost = UIImageView()

    private struct ResizeDrag {
        let corner: EditorImageCorner
        let startFrame: CGRect
        let startPoint: CGPoint
        let natural: MarkdownImageTag.Size?
        var size: MarkdownImageTag.Size?
    }

    private struct MoveDrag {
        let range: NSRange
        let startPoint: CGPoint
        var destination: Int?
    }

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
        buildLayers()
        buildGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Hit testing

    /// Claims only the handles.
    ///
    /// Everything else — including the middle of the picture — belongs to the
    /// text view underneath, so scrolling, the caret and text selection all
    /// behave exactly as they did before this view existed. The long press and
    /// tap recognisers are attached to the text view for the same reason.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, selection != nil else { return nil }
        return corner(at: point) == nil ? nil : self
    }

    /// The corner a touch at `point` takes hold of, or nil for the text.
    ///
    /// Both the target and the tie-break live in `EditorImageGeometry`, so the
    /// region that answers, the dot that is drawn, and the resize that follows
    /// cannot drift apart — and a Windows port gets the same numbers.
    func corner(at point: CGPoint) -> EditorImageCorner? {
        guard let selection else { return nil }
        return EditorImageGeometry.touchCorner(at: point, in: selection.rect)
    }

    // MARK: - Selection

    /// Show the frame around the picture at `range`, or hide it when nil.
    func show(range: NSRange?, rect: CGRect?) {
        guard let range, let rect, rect.width > 1, rect.height > 1 else {
            selection = nil
            isHidden = true
            return
        }
        selection = (range, rect)
        isHidden = false
        layoutDecorations()
    }

    var selectedRange: NSRange? { selection?.range }
    var isMoving: Bool { move != nil }

    // MARK: - Drawing

    private func buildLayers() {
        frameLayer.fillColor = nil
        frameLayer.strokeColor = UIColor.tintColor.cgColor
        frameLayer.lineWidth = 1
        layer.addSublayer(frameLayer)

        for corner in EditorImageCorner.allCases {
            let handle = CAShapeLayer()
            handle.fillColor = UIColor.systemBackground.cgColor
            handle.strokeColor = UIColor.tintColor.cgColor
            handle.lineWidth = 2
            layer.addSublayer(handle)
            handleLayers[corner] = handle
        }

        dropLine.backgroundColor = .tintColor
        dropLine.layer.cornerRadius = 1.5
        dropLine.isHidden = true
        addSubview(dropLine)

        ghost.alpha = 0.45
        ghost.contentMode = .scaleAspectFit
        ghost.isHidden = true
        addSubview(ghost)
    }

    private func layoutDecorations() {
        guard let selection else { return }
        frameLayer.path = UIBezierPath(rect: selection.rect).cgPath
        for corner in EditorImageCorner.allCases {
            let rect = EditorImageGeometry.handleRect(corner, in: selection.rect)
            handleLayers[corner]?.path = UIBezierPath(ovalIn: rect).cgPath
        }
    }

    // MARK: - Gestures

    private func buildGestures() {
        // On the overlay, because these only ever act on a handle.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleResize))
        addGestureRecognizer(pan)
    }

    @objc private func handleResize(_ recogniser: UIPanGestureRecognizer) {
        let point = recogniser.location(in: self)
        switch recogniser.state {
        case .began:
            guard let selection, let corner = corner(at: point) else { return }
            resize = ResizeDrag(
                corner: corner,
                startFrame: selection.rect,
                startPoint: point,
                natural: naturalSizeForImage?(selection.range),
                size: nil
            )
        case .changed:
            guard var drag = resize else { return }
            let width = EditorImageGeometry.draggedWidth(
                from: drag.startFrame,
                corner: drag.corner,
                deltaX: point.x - drag.startPoint.x,
                deltaY: point.y - drag.startPoint.y
            )
            // The same conversion macOS makes, so a width dragged on a phone
            // and on a Mac writes the same pair of numbers.
            let size = MarkdownImageTag.proportionalSize(
                MarkdownImageTag.Size(width: Int(width.rounded()), height: nil),
                natural: drag.natural,
                edited: .width
            )
            drag.size = size
            resize = drag
            preview(size)
        case .ended, .cancelled, .failed:
            defer { resize = nil }
            guard let drag = resize, let size = drag.size, let selection else { return }
            onResize?(selection.range, size)
        default:
            break
        }
    }

    // MARK: - Moving

    /// Begin carrying the selected picture. Driven by a long press on the text
    /// view, because a short drag on a touch screen is a scroll.
    func beginMove(range: NSRange, at point: CGPoint, image: UIImage?, size: CGSize) {
        move = MoveDrag(range: range, startPoint: point, destination: nil)
        isHidden = false
        frameLayer.isHidden = true
        for layer in handleLayers.values { layer.isHidden = true }
        ghost.image = image
        ghost.bounds = CGRect(origin: .zero, size: size)
        ghost.center = point
        ghost.isHidden = false
    }

    /// Update where the picture would land.
    func continueMove(to point: CGPoint, boundary: (location: Int, y: CGFloat)?) {
        guard move != nil else { return }
        move?.destination = boundary?.location
        ghost.center = point
        if let boundary {
            dropLine.frame = CGRect(x: 0, y: boundary.y - 1.5, width: bounds.width, height: 3)
            dropLine.isHidden = false
        } else {
            dropLine.isHidden = true
        }
    }

    /// Finish the gesture, committing the move if there is somewhere to put it.
    func endMove() {
        defer {
            move = nil
            ghost.isHidden = true
            dropLine.isHidden = true
            frameLayer.isHidden = false
            for layer in handleLayers.values { layer.isHidden = false }
        }
        guard let drag = move, let destination = drag.destination else { return }
        onMove?(drag.range, destination)
    }

    private func preview(_ size: MarkdownImageTag.Size) {
        guard let selection, let width = size.width else { return }
        let height = size.height ?? Int(
            (CGFloat(width) * selection.rect.height / max(selection.rect.width, 1)).rounded()
        )
        let previewed = CGRect(
            origin: selection.rect.origin,
            size: CGSize(width: CGFloat(width), height: CGFloat(height))
        )
        self.selection = (selection.range, previewed)
        layoutDecorations()
    }
}
