import AppKit
import MarkdownEditorCore
import MarkdownEditorUI

@MainActor
final class RichMarkdownTextView: NSTextView {
    static let markdownPasteboardType = NSPasteboard.PasteboardType(
        "com.kirupa.markdown-editor.source"
    )

    var compositionDidBegin: ((NSRange) -> Void)?
    var compositionDidCommit: (() -> Void)?
    var markdownForRenderedRange: ((NSRange) -> String)?
    var replaceSelectionWithMarkdown: ((String, String) -> Void)?
    /// The image's own pixel size, so a drag can keep its shape.
    var naturalSizeForImage: ((NSTextAttachment) -> MarkdownImageTag.Size?)?
    /// A finished drag, as one undoable edit on the document's source text.
    /// Commit a resize for the image the handles are drawn around. The rendered
    /// range is passed so the commit does not have to re-find the picture.
    var commitImageSize: ((MarkdownImageTag.Size, NSRange) -> Void)?
    /// Move the picture occupying the first range so it sits at the second
    /// location, both measured in rendered text.
    var moveImage: ((NSRange, Int) -> Void)?

    private(set) var isUpdatingComposition = false
    /// The pictures the pointer should turn into an arrow over, and the
    /// visible area they were measured for.
    private var pointerRects: (visible: NSRect, length: Int, rects: [NSRect])?
    private var pointerTracking: NSTrackingArea?
    private lazy var imageHover: MarkdownImageHoverOverlay = {
        let overlay = MarkdownImageHoverOverlay(frame: .zero)
        addSubview(overlay, positioned: .below, relativeTo: imageHandles)
        return overlay
    }()

    private lazy var dropCaret: MarkdownImageDropCaret = {
        let caret = MarkdownImageDropCaret(frame: .zero)
        addSubview(caret, positioned: .above, relativeTo: imageHandles)
        return caret
    }()

    private lazy var dragGhost: MarkdownImageDragGhost = {
        let ghost = MarkdownImageDragGhost(frame: .zero)
        addSubview(ghost, positioned: .above, relativeTo: imageHandles)
        return ghost
    }()

    private var compositionIsActive = false
    private weak var compositionUndoManager: UndoManager?
    private lazy var imageHandles: MarkdownImageHandleOverlay = {
        let overlay = MarkdownImageHandleOverlay(frame: .zero)
        overlay.isHidden = true
        overlay.onPreview = { [weak self] size in
            self?.previewImageSize(size)
        }
        overlay.onCommit = { [weak self] size in
            guard let self else { return }
            // A drag only changed the attachment's bounds; the document never
            // heard about it. Put the picture back the way the document has it
            // and let the commit re-render at the new size. A commit that is
            // refused — no image at the selection, no editor — then leaves the
            // picture agreeing with the text instead of stuck at the size the
            // drag abandoned it at.
            self.restorePreviewedImageSize()
            guard let range = self.handledImageRange else { return }
            self.commitImageSize?(size, range)
        }
        addSubview(overlay)
        return overlay
    }()


    /// The character range of the image the handles are drawn around.
    private var handledImageRange: NSRange?
    private var isSelectionHighlightHidden = false
    /// The attachment's bounds before a live drag started, so a cancelled or
    /// rejected resize can put the picture back the way it was.
    private var handledImageBounds: CGRect?

    // MARK: - Image selection

    /// Select the image under `point`, if there is one.
    ///
    /// A single character is selected rather than a caret placed, because the
    /// commands that act on an image all read the selection, and because a
    /// selected picture should look selected.
    @discardableResult
    private func selectImage(at point: NSPoint) -> Bool {
        guard let range = imageRange(at: point) else { return false }
        setSelectedRange(range)
        return true
    }

    /// The same decision a click makes, reachable from `check-image-layout`.
    ///
    /// The harness has to go through the real entry point rather than repeat
    /// its reasoning, or it verifies a copy of the logic instead of the logic.
    /// The handle overlay, for the same harness.
    var imageHandlesForChecking: MarkdownImageHandleOverlay { imageHandles }


    @discardableResult
    func selectImageForChecking(at point: NSPoint) -> Bool {
        selectImage(at: point)
    }

    /// The attachment in a range, so the harness can watch its drawn bounds.
    func attachmentForChecking(in range: NSRange) -> NSTextAttachment? {
        attachment(in: range)
    }

    /// Drive a live drag preview, as `mouseDragged` does.
    func previewImageSizeForChecking(_ size: MarkdownImageTag.Size) {
        previewImageSize(size)
    }

    /// Drive the end of a drag, as `mouseUp` does.
    func commitImageSizeForChecking(_ size: MarkdownImageTag.Size) {
        restorePreviewedImageSize()
        guard let range = handledImageRange else { return }
        commitImageSize?(size, range)
    }

    /// The single-character range of the image drawn under `point`.
    private func imageRange(at point: NSPoint) -> NSRange? {
        guard
            let layoutManager,
            let textContainer,
            textStorage != nil
        else { return nil }

        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: inContainer,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        guard index <= (textStorage?.length ?? 0) else { return nil }

        // `characterIndex(for:)` answers with the nearest *insertion point*,
        // so a click on the right half of a picture can come back as the
        // character after it. Both neighbours are tried, and the rect is what
        // decides: a click only counts when it really landed on the image.
        for candidate in [index, index - 1] {
            guard candidate >= 0, candidate < (textStorage?.length ?? 0) else {
                continue
            }
            let range = NSRange(location: candidate, length: 1)
            guard attachment(in: range) != nil else { continue }
            guard let rect = imageRect(for: range), rect.contains(point) else {
                continue
            }
            return range
        }
        return nil
    }

    private func attachment(in range: NSRange) -> NSTextAttachment? {
        guard
            let textStorage,
            range.location >= 0,
            NSMaxRange(range) <= textStorage.length
        else { return nil }
        return textStorage.attribute(
            .attachment,
            at: range.location,
            effectiveRange: nil
        ) as? NSTextAttachment
    }

    /// Where the image at `range` is really drawn, in this view's coordinates.
    ///
    /// `boundingRect(forGlyphRange:in:)` answers with the glyph's *line* box,
    /// which is as tall as the tallest thing on that line and carries the
    /// paragraph's line spacing. Using it would accept clicks in the blank
    /// strip above and below the picture and draw the frame around that empty
    /// space. An attachment sits on the baseline with a size of its own, so the
    /// exact rect is the line fragment's origin, plus the glyph's offset inside
    /// it, sized by the attachment.
    func imageRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphs.length > 0 else { return nil }
        let origin = textContainerOrigin

        guard
            let attachment = attachment(in: range),
            attachment.bounds.width > 0,
            attachment.bounds.height > 0
        else {
            // An attachment that never set its own bounds is drawn at whatever
            // size the layout manager gave it, so the glyph box is all there is.
            var rect = layoutManager.boundingRect(
                forGlyphRange: glyphs,
                in: textContainer
            )
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            return rect
        }

        let fragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphs.location,
            effectiveRange: nil
        )
        return EditorImageGeometry.attachmentRect(
            lineFragment: fragment,
            glyphLocation: layoutManager.location(forGlyphAt: glyphs.location),
            attachmentSize: attachment.bounds.size,
            containerOrigin: origin
        )
    }

    /// Put the handles where the selected image is, or take them away.
    func updateImageHandles() {
        let selection = selectedRange()
        guard
            selection.length == 1,
            let attachment = attachment(in: selection),
            let rect = imageRect(for: selection)
        else {
            imageHandles.hide()
            handledImageRange = nil
            handledImageBounds = nil
            setSelectionHighlightHidden(false)
            refreshImageCursorRects()
            return
        }
        handledImageRange = selection
        // Not while dragging: a live preview rewrites these bounds, and
        // recording the previewed size here would lose the only record of what
        // the document actually says.
        if !imageHandles.isDragging {
            handledImageBounds = attachment.bounds
        }
        setSelectionHighlightHidden(true)
        imageHandles.show(
            around: rect,
            naturalSize: naturalSizeForImage?(attachment)
        )
        refreshImageCursorRects()
    }

    /// Whether AppKit should paint its selection band behind the selection.
    ///
    /// It should not, when the selection is a picture. The band is drawn over
    /// the line fragment, which is taller than the image, so a selected picture
    /// showed a coloured strip below it that did not line up with anything —
    /// it reads as a misdrawn frame. The frame and its handles say "selected"
    /// on their own, which is how every other editor shows a selected image.
    private func setSelectionHighlightHidden(_ hidden: Bool) {
        guard hidden != isSelectionHighlightHidden else { return }
        isSelectionHighlightHidden = hidden
        applySelectedTextAttributes()
    }

    /// The theme's selection colours, kept apart from what is on screen.
    ///
    /// A theme can be applied at any moment, including while a picture is
    /// selected. If the cleared attributes were simply overwritten the band
    /// would come back and stay back, so the theme sets this and the view
    /// decides what to show.
    var baseSelectedTextAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet { applySelectedTextAttributes() }
    }

    private func applySelectedTextAttributes() {
        var attributes = baseSelectedTextAttributes
        if isSelectionHighlightHidden {
            attributes[.backgroundColor] = NSColor.clear
        }
        selectedTextAttributes = attributes
    }

    // MARK: - Cursors

    /// Every image laid out near the visible area, in this view's coordinates.
    ///
    /// Limited to what is on screen because asking for an image's rect forces
    /// that part of the document to be laid out, and a long document full of
    /// pictures should not be measured end to end just to choose a cursor.
    private func visibleImageRects() -> [NSRect] {
        guard
            let textStorage,
            let layoutManager,
            let textContainer
        else { return [] }

        let glyphs = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let characters = layoutManager.characterRange(
            forGlyphRange: glyphs,
            actualGlyphRange: nil
        )
        guard
            characters.length > 0,
            NSMaxRange(characters) <= textStorage.length
        else { return [] }

        var rects: [NSRect] = []
        textStorage.enumerateAttribute(
            .attachment,
            in: characters
        ) { value, range, _ in
            guard value is NSTextAttachment, range.length == 1 else { return }
            if let rect = imageRect(for: range) {
                rects.append(rect)
            }
        }
        return rects
    }

    /// The rects a picture claims for the pointer, and the shape shown there.
    ///
    /// Not something registered on this view — see `resetCursorRects`. Kept
    /// readable because AppKit does not hand registered cursor rects back.
    func imageCursorRects() -> [(rect: NSRect, cursor: NSCursor)] {
        visibleImageRects().map { ($0, NSCursor.arrow) }
    }

    override func resetCursorRects() {
        // Order matters, and not in the direction the documentation suggests.
        // These were once added after `super`, which registers a single I-beam
        // over the whole surface, and the I-beam won: measured on a real
        // screen the pointer over a picture was an I-beam at 0.96 confidence.
        // The earlier claim on a region is the one AppKit keeps, so a picture
        // has to stake its claim before the text view stakes the general one.
        //
        // `super` still runs, so everything NSTextView does for itself —
        // links included — carries on untouched.
        for entry in imageCursorRects() {
            addCursorRect(entry.rect, cursor: entry.cursor)
        }
        super.resetCursorRects()
    }

    /// Ask the window to re-read the cursor rects.
    ///
    /// They are cached, so a picture that has just moved, been resized, or
    /// scrolled into view keeps the cursor of wherever it used to be until the
    /// window is told otherwise.
    func refreshImageCursorRects() {
        pointerRects = nil
        installPointerTracking()
        // Selecting, scrolling or reflowing moves pictures under a pointer that
        // has not itself moved, so no mouseMoved arrives to correct the
        // outline. Ask where the pointer is instead of waiting to be told.
        if let window {
            updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        guard let window, window.isVisible else { return }
        window.invalidateCursorRects(for: self)
        if !imageHandles.isHidden {
            window.invalidateCursorRects(for: imageHandles)
        }
    }

    /// The pictures currently on screen, measured at most once per visible area.
    ///
    /// Deliberately not a value that is only refreshed when the selection or
    /// the scroll position changes. Opening a document and moving the pointer
    /// straight onto a picture does neither, and that is the ordinary way to
    /// meet a picture: the cache was empty and every one of them showed an
    /// I-beam.
    private func pointerImageRects() -> [NSRect] {
        let visible = visibleRect
        let length = textStorage?.length ?? 0
        if let cached = pointerRects, cached.visible == visible, cached.length == length {
            return cached.rects
        }
        let rects = visibleImageRects()
        pointerRects = (visible, length, rects)
        return rects
    }

    /// Have AppKit tell this view whenever the pointer needs a shape.
    ///
    /// Cursor rects are not enough. NSTextView claims its whole surface for the
    /// I-beam and re-asserts that claim, and a view layered on top that
    /// declines hit tests does not get to override it either — both were
    /// measured on a real screen still showing an I-beam over a picture, at
    /// 0.96 confidence. A tracking area owned by this view is delivered to
    /// `cursorUpdate` regardless.
    ///
    /// One area over the whole visible rect rather than one per picture: a
    /// cursor stays set until something replaces it, so if this only fired over
    /// pictures the arrow would follow the pointer back out onto the text.
    /// `.inVisibleRect` keeps it the right size through every scroll and
    /// resize without being rebuilt.
    private func installPointerTracking() {
        if let existing = pointerTracking, trackingAreas.contains(existing) { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .cursorUpdate, .mouseMoved, .mouseEnteredAndExited,
                .activeAlways, .inVisibleRect,
            ],
            owner: self
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    /// NSTextView rebuilds its own tracking areas, and anything added once at
    /// setup can be dropped when it does. This is the documented place to put
    /// them back, and the guard above makes it idempotent.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installPointerTracking()
    }

    /// The shape the pointer should take at `point`, in this view's coordinates.
    ///
    /// This view is the only thing deciding, so the answer is whatever it says
    /// — which is what makes it checkable without a screen.
    func pointerCursor(at point: NSPoint) -> NSCursor {
        // A corner of the selected picture resizes it, and that beats the
        // picture's own shape. The handles own these rects, so ask them.
        if !imageHandles.isHidden {
            let local = imageHandles.convert(point, from: self)
            if let entry = imageHandles.cursorRects().first(where: { $0.rect.contains(local) }) {
                return entry.cursor
            }
        }
        // A picture is an object to be selected and dragged, not somewhere to
        // type, so it gets the arrow every other draggable object gets.
        if pointerImageRects().contains(where: { $0.contains(point) }) {
            return .arrow
        }
        // Taking the cursor over means taking over the cases AppKit used to
        // handle, and a link showing an I-beam would be a regression.
        if hasLink(at: point) {
            return .pointingHand
        }
        return .iBeam
    }

    override func cursorUpdate(with event: NSEvent) {
        pointerCursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    // MARK: - Hover

    /// The picture the pointer is over, in this view's coordinates.
    private(set) var hoveredImageRect: NSRect?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: nil)
    }

    /// Outline the picture under `point`, if any.
    ///
    /// The selected picture is skipped: it already has a frame, and drawing
    /// both would put two rectangles around one image.
    func updateHover(at point: NSPoint?) {
        let rect = point.flatMap { p in
            pointerImageRects().first { $0.contains(p) }
        }
        let selected = imageHandles.isHidden ? nil : handledImageRect
        hoveredImageRect = rect == selected ? nil : rect
        imageHover.show(around: hoveredImageRect)
    }

    /// The rect the handles are drawn around, in this view's coordinates.
    private var handledImageRect: NSRect? {
        guard let handledImageRange else { return nil }
        return imageRect(for: handledImageRange)
    }

    /// Whether `point` lands on linked text.
    ///
    /// The glyph nearest a point is not necessarily under it — past the end of
    /// a line the nearest glyph is the last one on that line — so the point has
    /// to be inside the glyph's own rect before its attributes mean anything.
    private func hasLink(at point: NSPoint) -> Bool {
        guard
            let layoutManager,
            let textContainer,
            let textStorage,
            layoutManager.numberOfGlyphs > 0
        else { return false }

        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(
            for: inContainer,
            in: textContainer,
            fractionOfDistanceThroughGlyph: &fraction
        )
        guard glyph < layoutManager.numberOfGlyphs else { return false }
        let glyphRect = layoutManager
            .boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
        guard glyphRect.contains(point) else { return false }

        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < textStorage.length else { return false }
        return textStorage.attribute(.link, at: index, effectiveRange: nil) != nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installPointerTracking()
        // Tracking areas report through the event stream, and a window that is
        // not asking for mouse-moved events does not pump it. Without this the
        // pointer keeps whatever shape it had until the window is clicked, so
        // a picture met by hovering straight after opening a document — which
        // is how a picture is usually met — stays an I-beam.
        window?.acceptsMouseMovedEvents = true
        // Registration is unbalanced otherwise: this runs again every time the
        // view moves to or from a window, including the teardown call where the
        // scroll view is still attached, so observers accumulate on one clip
        // view.
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.frameDidChangeNotification,
            object: nil
        )
        guard window != nil else {
            // Leaving the window mid-drag would otherwise strand a pushed
            // cursor on the process-wide stack for every other app to inherit.
            imageHandles.hide()
            return
        }
        guard let clipView = enclosingScrollView?.contentView else { return }
        // Only the images near the visible area get a cursor rect, so scrolling
        // brings pictures into view that the window has never been told about.
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibleAreaDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        // Re-wrapping the text above a picture moves it without changing either
        // the selection or the document, so nothing else would reposition the
        // handles. They would keep their old frame over blank text and stay the
        // live drag target there. A width drag or a window resize does this.
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textLayoutDidChange),
            name: NSView.frameDidChangeNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func visibleAreaDidChange() {
        refreshImageCursorRects()
    }

    @objc private func textLayoutDidChange() {
        // Not while a corner is being dragged: the drag is already moving the
        // picture, and re-deriving the frame underneath it fights the gesture.
        guard !imageHandles.isDragging else { return }
        updateImageHandles()
    }

    /// Draw the image at a new size without touching the document.
    ///
    /// A drag rewriting the text on every step would put a hundred entries in
    /// the undo stack and re-render the document a hundred times. Changing the
    /// attachment's bounds shows the same thing and costs a relayout.
    private func previewImageSize(_ size: MarkdownImageTag.Size) {
        guard
            let range = handledImageRange,
            let attachment = attachment(in: range),
            let width = size.width,
            width > 0
        else { return }

        let height = size.height ?? Int(
            (CGFloat(width) * attachment.bounds.height
                / max(1, attachment.bounds.width)).rounded()
        )
        attachment.bounds = CGRect(
            x: attachment.bounds.origin.x,
            y: attachment.bounds.origin.y,
            width: CGFloat(width),
            height: CGFloat(max(1, height))
        )
        layoutManager?.invalidateLayout(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        layoutManager?.invalidateDisplay(forCharacterRange: range)
        // The frame has to follow the picture, or the handles drift away from
        // the corners they are supposed to be holding.
        DispatchQueue.main.async { [weak self] in
            self?.updateImageHandles()
        }
    }

    /// Undo a live preview, putting the picture back at the document's size.
    private func restorePreviewedImageSize() {
        guard
            let range = handledImageRange,
            let bounds = handledImageBounds,
            let attachment = attachment(in: range),
            attachment.bounds != bounds
        else { return }
        attachment.bounds = bounds
        layoutManager?.invalidateLayout(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        layoutManager?.invalidateDisplay(forCharacterRange: range)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selectImage(at: point) {
            // `NSTextView` takes first responder inside its own `mouseDown`,
            // and this path deliberately does not call super. Without taking it
            // here, clicking a picture in the preview leaves focus in whichever
            // pane had it, so the resize that follows is committed against the
            // *other* pane's caret — which rewrites a different image, or none.
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
                // Focus arrived after the selection was set, so the selection
                // notification was ignored as unfocused. Say it again.
                setSelectedRange(selectedRange())
            }
            updateImageHandles()
            beginImageMove(at: point)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: - Moving a picture

    /// Where a press on a picture started, and what it was on.
    private var imageMoveRange: NSRange?
    private var imageMoveOrigin: NSPoint?
    private var imageMoveGrabOffset: NSSize = .zero
    private(set) var isMovingImage = false
    /// Where the picture would land if it were dropped now.
    private(set) var imageDropLocation: Int?

    /// Far enough that a click with an unsteady hand is still a click.
    private static let imageMoveThreshold: CGFloat = 4

    private func beginImageMove(at point: NSPoint) {
        guard let range = handledImageRange, let rect = imageRect(for: range) else { return }
        imageMoveRange = range
        imageMoveOrigin = point
        imageMoveGrabOffset = NSSize(
            width: point.x - rect.midX,
            height: point.y - rect.midY
        )
        isMovingImage = false
        imageDropLocation = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = imageMoveOrigin, let range = imageMoveRange else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if !isMovingImage {
            let dx = point.x - origin.x, dy = point.y - origin.y
            guard (dx * dx + dy * dy).squareRoot() > Self.imageMoveThreshold else { return }
            isMovingImage = true
            // The handles belong to a picture sitting in the text. While it is
            // being carried they would be drawn around where it used to be.
            imageHandles.hide()
            imageHover.show(around: nil)
        }
        updateImageDrop(at: point, range: range)
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let range = imageMoveRange else {
            super.mouseUp(with: event)
            return
        }
        let moving = isMovingImage
        let destination = imageDropLocation
        endImageMove()
        guard moving, let destination else {
            updateImageHandles()
            return
        }
        moveImage?(range, destination)
    }

    /// Show where the picture would land, and carry a copy of it there.
    private func updateImageDrop(at point: NSPoint, range: NSRange) {
        let location = dropLocation(for: point, moving: range)
        imageDropLocation = location
        dropCaret.show(at: location.flatMap { insertionRect(at: $0) })
        if let rect = imageRect(for: range) {
            dragGhost.show(
                movingImage(in: range),
                size: rect.size,
                centredOn: NSPoint(
                    x: point.x - imageMoveGrabOffset.width,
                    y: point.y - imageMoveGrabOffset.height
                )
            )
        }
    }

    /// The picture being carried, however the attachment happens to hold it.
    private func movingImage(in range: NSRange) -> NSImage? {
        guard let attachment = attachment(in: range) else { return nil }
        if let image = attachment.image { return image }
        return (attachment.attachmentCell as? NSTextAttachmentCell)?.image
    }

    /// The character the picture would be inserted before.
    ///
    /// Inside its own text is not a destination — that is a drop back where it
    /// started — so those points report nothing and the caret disappears,
    /// which is how a person can tell the gesture will be a no-op.
    private func dropLocation(for point: NSPoint, moving range: NSRange) -> Int? {
        let index = characterIndexForInsertion(at: point)
        guard index < range.location || index > NSMaxRange(range) else { return nil }
        return index
    }

    /// A caret-shaped rect at `location`, in this view's coordinates.
    func insertionRect(at location: Int) -> NSRect? {
        guard
            let layoutManager,
            let textContainer,
            let textStorage
        else { return nil }
        let origin = textContainerOrigin
        if textStorage.length == 0 {
            let rect = layoutManager.extraLineFragmentRect
            return rect.isEmpty ? nil : rect.offsetBy(dx: origin.x, dy: origin.y)
        }
        // Past the last character there is no glyph to measure, so measure the
        // last one and stand at its trailing edge instead.
        let atEnd = location >= textStorage.length
        let character = atEnd ? textStorage.length - 1 : location
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var rect = layoutManager
            .boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
        if atEnd { rect.origin.x = rect.maxX }
        return NSRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
    }

    private func endImageMove() {
        imageMoveRange = nil
        imageMoveOrigin = nil
        isMovingImage = false
        imageDropLocation = nil
        dropCaret.show(at: nil)
        dragGhost.hide()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(
            ranges,
            affinity: affinity,
            stillSelecting: stillSelecting
        )
        guard !stillSelecting else { return }
        updateImageHandles()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCodeBlockBackgrounds(in: rect)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if !compositionIsActive {
            compositionIsActive = true
            compositionUndoManager = undoManager
            compositionUndoManager?.disableUndoRegistration()
            let range = replacementRange.location == NSNotFound
                ? self.selectedRange()
                : replacementRange
            compositionDidBegin?(range)
        }

        isUpdatingComposition = true
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
    }

    override func insertText(
        _ insertString: Any,
        replacementRange: NSRange
    ) {
        guard compositionIsActive else {
            super.insertText(
                insertString,
                replacementRange: replacementRange
            )
            return
        }

        isUpdatingComposition = true
        super.insertText(
            insertString,
            replacementRange: replacementRange
        )
        isUpdatingComposition = false
        finishComposition()
    }

    override func unmarkText() {
        super.unmarkText()
        if !isUpdatingComposition {
            finishComposition()
        }
    }

    func finishPendingComposition() {
        guard compositionIsActive else {
            return
        }
        isUpdatingComposition = true
        super.unmarkText()
        isUpdatingComposition = false
        finishComposition()
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0,
            let markdown = markdownForRenderedRange?(selection)
        else {
            super.copy(sender)
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            markdown,
            forType: Self.markdownPasteboardType
        )
        pasteboard.setString(markdown, forType: .string)
    }

    override func cut(_ sender: Any?) {
        finishPendingComposition()
        guard selectedRange().length > 0 else {
            return
        }
        copy(sender)
        replaceSelectionWithMarkdown?("", "Cut")
    }

    override func paste(_ sender: Any?) {
        finishPendingComposition()
        let pasteboard = NSPasteboard.general
        if let markdown = pasteboard.string(
            forType: Self.markdownPasteboardType
        ) {
            replaceSelectionWithMarkdown?(markdown, "Paste")
            return
        }
        if let plainText = pasteboard.string(forType: .string) {
            insertText(plainText, replacementRange: selectedRange())
            return
        }

        NSSound.beep()
    }

    private func finishComposition() {
        guard compositionIsActive else {
            return
        }
        compositionIsActive = false
        compositionUndoManager?.enableUndoRegistration()
        compositionUndoManager = nil
        compositionDidCommit?()
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        guard let textStorage,
            let layoutManager,
            let textContainer,
            textStorage.length > 0
        else {
            return
        }

        let textContainerOrigin = self.textContainerOrigin
        textStorage.enumerateAttribute(
            .markdownCodeBlockBackground,
            in: NSRange(location: 0, length: textStorage.length)
        ) { value, characterRange, _ in
            guard let backgroundColor = value as? NSColor else {
                return
            }

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else {
                return
            }

            var verticalBounds = NSRect.null
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { lineRect, _, _, lineGlyphRange, _ in
                guard NSIntersectionRange(
                    glyphRange,
                    lineGlyphRange
                ).length > 0 else {
                    return
                }
                let positionedLineRect = lineRect.offsetBy(
                    dx: textContainerOrigin.x,
                    dy: textContainerOrigin.y
                )
                verticalBounds = verticalBounds.isNull
                    ? positionedLineRect
                    : verticalBounds.union(positionedLineRect)
            }

            guard !verticalBounds.isNull,
                textContainer.size.width.isFinite
            else {
                return
            }

            let horizontalInset: CGFloat = 4
            let verticalPadding: CGFloat = 3
            let blockRect = NSRect(
                x: textContainerOrigin.x + horizontalInset,
                y: verticalBounds.minY - verticalPadding,
                width: max(
                    0,
                    textContainer.size.width - (horizontalInset * 2)
                ),
                height: verticalBounds.height + (verticalPadding * 2)
            )
            guard blockRect.width > 0,
                blockRect.intersects(dirtyRect)
            else {
                return
            }

            backgroundColor.setFill()
            NSBezierPath(
                roundedRect: blockRect,
                xRadius: 5,
                yRadius: 5
            ).fill()
        }
    }
}

extension NSAttributedString.Key {
    static let markdownCodeBlockBackground = Self(
        "com.kirupa.markdown-editor.code-block-background"
    )
}
