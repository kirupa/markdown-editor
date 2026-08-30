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

    private lazy var dropLine: MarkdownImageDropLine = {
        let line = MarkdownImageDropLine(frame: .zero)
        addSubview(line, positioned: .above, relativeTo: imageHandles)
        return line
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

    /// The picture at a point, so a check can confirm a press will land on one
    /// before making it. A press that misses falls through to NSTextView's own
    /// mouseDown, which runs a modal tracking loop waiting for a real mouse up
    /// — a synthesised drag never delivers one, and the check hangs.
    func imageRangeForChecking(at point: NSPoint) -> NSRange? {
        imageRange(at: point)
    }


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
        showHandles(around: selectedImageRange() ?? hoveredImageRange)
    }

    /// The selection, when the selection is a picture.
    private func selectedImageRange() -> NSRange? {
        let selection = selectedRange()
        guard selection.length == 1, attachment(in: selection) != nil else { return nil }
        return selection
    }

    /// Draw the resize frame around `range`, or hide it when nothing qualifies.
    ///
    /// The frame follows the hovered picture as well as the selected one. It
    /// used to appear only once a picture had been clicked, which meant the
    /// thing telling you a picture *can* be resized only showed up after you
    /// had already guessed that it could.
    private func showHandles(around range: NSRange?) {
        guard
            let range,
            let attachment = attachment(in: range),
            let rect = imageRect(for: range)
        else {
            imageHandles.hide()
            handledImageRange = nil
            handledImageBounds = nil
            setSelectionHighlightHidden(false)
            refreshImageCursorRects()
            return
        }
        handledImageRange = range
        // Not while dragging: a live preview rewrites these bounds, and
        // recording the previewed size here would lose the only record of what
        // the document actually says.
        if !imageHandles.isDragging {
            handledImageBounds = attachment.bounds
        }
        setSelectionHighlightHidden(selectedImageRange() != nil)
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
        var rects: [(rect: NSRect, cursor: NSCursor)] = []
        for range in visibleImageRanges() {
            guard let rect = imageRect(for: range) else { continue }
            // Corners first: they overlap the picture's own edges, and the
            // earlier claim on a region is the one AppKit keeps.
            //
            // These have to be real cursor rects. A tracking area asking for
            // `cursorUpdate` looks like it should do the job and does not:
            // measured against the running app, cursorUpdate arrived 6 times
            // across 99 mouse moves — only when the pointer crossed the edge of
            // some *rect*. Over a corner there was no rect to cross, so nothing
            // was ever asked and NSTextView's I-beam simply stayed. That is the
            // whole of the "resize cursor never appears" fault.
            for corner in EditorImageCorner.allCases {
                rects.append(
                    (EditorImageGeometry.handleHitRect(corner, in: rect), corner.cursor)
                )
            }
            rects.append((rect, NSCursor.pointingHand))
        }
        return rects
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
        // Reflow moves a hovered picture under a pointer that has not itself
        // moved, so the outline has to be re-measured. Only its geometry:
        // re-deciding *which* picture is hovered from here would call back
        // into the code that is asking, and the frame would be hidden by the
        // very act of showing it.
        refreshHoverGeometry()
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
        // A corner resizes, and that beats the picture's own shape.
        //
        // Asked of the geometry, not of the overlay. AppKit delivers
        // cursorUpdate and mouseMoved as separate events, so a cursorUpdate can
        // arrive while the overlay is still hidden — the first sight of a
        // corner then gave the wrong pointer, and nothing corrected it until
        // the pointer moved again. That was the delay: the shape was waiting
        // for a view to catch up rather than reading the picture.
        if let range = selectedImageRange() ?? hoveredImageRange ?? imageRangeNear(point),
           let rect = imageRect(for: range),
           let corner = EditorImageGeometry.corner(at: point, in: rect) {
            return corner.cursor
        }
        // A picture is something to pick up, so it gets the hand that every
        // other grabbable thing gets. The arrow only says "not text", which is
        // not the same as saying "you can take hold of this".
        if pointerImageRects().contains(where: { $0.contains(point) }) {
            return .pointingHand
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

    /// Where that picture is, in this view's coordinates.
    private(set) var hoveredImageRect: NSRect?

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateHover(at: point)
        // Set the shape here, on every move, and not only from `cursorUpdate`.
        //
        // Measured against the running app: `super.mouseMoved` puts the I-beam
        // back on every single move, and `cursorUpdate` only arrives when the
        // pointer crosses the edge of a registered rect — 6 times across 99
        // moves. Inside a corner target no edge is crossed, so nothing ever
        // asked for the shape again and the I-beam NSTextView had just set
        // simply stayed. The rects were correct and the geometry agreed; the
        // shape was being overwritten immediately afterwards by the superclass.
        pointerCursor(at: point).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: nil)
    }

    /// The picture the pointer is over.
    private(set) var hoveredImageRange: NSRange?

    /// Re-measure the hovered picture without re-deciding which one it is.
    private func refreshHoverGeometry() {
        guard let range = hoveredImageRange else { return }
        hoveredImageRect = imageRect(for: range)
        imageHover.show(
            around: selectedImageRange() == range ? nil : hoveredImageRect
        )
    }

    /// The picture the pointer is interacting with, which is not the same as
    /// the picture it is on top of.
    ///
    /// A resize handle is centred on the picture's corner, so its outer half
    /// lies outside the picture entirely. Defining hover as "over the picture"
    /// therefore takes the handles away at the exact moment somebody reaches
    /// for one, and the resize pointer never appears at all. The picture keeps
    /// the pointer for as far out as its own handles are drawn.
    private func hoverRange(at point: NSPoint) -> NSRange? {
        if let onPicture = imageRange(at: point) { return onPicture }
        // Only the corners reach out, and only as far as their own hit rects.
        // A uniform halo would light a picture up when the pointer is plainly
        // beside it rather than on it — the reach exists for the handles, so
        // it should be exactly the handles.
        for range in visibleImageRanges() {
            guard let rect = imageRect(for: range) else { continue }
            if EditorImageGeometry.corner(at: point, in: rect) != nil { return range }
        }
        return nil
    }

    /// The picture whose handles `point` falls on, without needing hover to
    /// have run first.
    private func imageRangeNear(_ point: NSPoint) -> NSRange? {
        for range in visibleImageRanges() {
            guard let rect = imageRect(for: range) else { continue }
            if rect.contains(point)
                || EditorImageGeometry.corner(at: point, in: rect) != nil {
                return range
            }
        }
        return nil
    }

    /// Every picture laid out near the visible area, as ranges.
    private func visibleImageRanges() -> [NSRange] {
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
        var ranges: [NSRange] = []
        textStorage.enumerateAttribute(.attachment, in: characters) { value, range, _ in
            if value is NSTextAttachment, range.length == 1 { ranges.append(range) }
        }
        return ranges
    }

    /// Outline the picture under `point` and put the resize frame on it.
    ///
    /// The outline is suppressed for the selected picture, which already has a
    /// frame of its own — two rectangles around one picture reads as a bug.
    func updateHover(at point: NSPoint?) {
        // Nothing may move while a picture is being carried or resized: the
        // pointer is a long way from the picture it is acting on.
        guard !isMovingImage, !imageHandles.isDragging else { return }

        let range = point.flatMap { hoverRange(at: $0) }
        let rect = range.flatMap { imageRect(for: $0) }
        let changed = range != hoveredImageRange
        hoveredImageRange = range
        hoveredImageRect = rect

        let selected = selectedImageRange()
        imageHover.show(around: range == selected ? nil : rect)
        if changed { showHandles(around: selected ?? range) }
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
        // Nor while a picture is being carried — opening the gap relays out the
        // document, which would call straight back in here.
        guard !imageHandles.isDragging, !isMovingImage else { return }
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
    /// The band held open for the picture, in this view's coordinates.
    private(set) var dropGap: NSRect?
    /// The size the picture is drawn at, captured before the gap moves it.
    private var movingImageSize: NSSize?

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
        // Captured now: once the gap opens, the picture's own rect moves.
        movingImageSize = rect.size
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
        let target = dropBoundary(for: point, moving: range)?.location
        // Rebuilt only when the target paragraph changes. The band is what
        // moved the text, so re-deriving it every mouse move from a layout it
        // is already distorting makes the gap chase itself down the page.
        if target != imageDropLocation {
            imageDropLocation = target
            closeDropGap()
            if let target, let y = settledBoundaryY(at: target) {
                openDropGap(atY: y, height: movingImageSize?.height ?? 0)
            }
        }
        if let size = movingImageSize {
            dragGhost.show(
                movingImage(in: range),
                size: size,
                centredOn: NSPoint(
                    x: point.x - imageMoveGrabOffset.width,
                    y: point.y - imageMoveGrabOffset.height
                )
            )
        }
    }

    /// Where the picture would be inserted, and the y of the line between.
    ///
    /// Always a line boundary. A picture belongs between two lines, so the
    /// nearest edge of the line under the pointer is the answer, never the
    /// nearest character.
    func dropBoundary(for point: NSPoint, moving range: NSRange) -> (location: Int, y: CGFloat)? {
        guard
            let layoutManager,
            let textContainer,
            let textStorage,
            textStorage.length > 0
        else { return nil }
        let string = textStorage.string as NSString

        // While the pointer is inside the gap the answer must not change, or
        // the gap moves the text that decided where the gap goes.
        if let gap = dropGap, point.y >= gap.minY, point.y <= gap.maxY,
           let held = imageDropLocation {
            return (held, gap.minY)
        }

        let origin = textContainerOrigin
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let character = min(
            layoutManager.characterIndexForGlyph(at: glyph),
            max(0, string.length - 1)
        )

        // Whole paragraphs, not line fragments. A fragment is a *visual* line,
        // so a wrapped paragraph's fragment ends in the middle of a sentence,
        // and taking its edge as an insertion point puts the picture there. A
        // real drag aimed below the last paragraph resolved to an offset 51
        // characters into an earlier one for exactly this reason.
        let paragraph = string.lineRange(
            for: NSRange(location: character, length: 0)
        )
        let rect = paragraphRect(paragraph) ?? .zero
        let below = point.y > rect.midY
        let location = below ? NSMaxRange(paragraph) : paragraph.location
        let y = below ? rect.maxY : rect.minY

        // Landing anywhere the picture already effectively is, is not a move.
        // That is its own line *and* the blank lines that separate it from its
        // neighbours: dropping into the gap directly above or below a picture
        // puts it back exactly where it started. Guarding only its own line
        // still drew a rule and held a gap open at a place where releasing did
        // nothing, which promises a move the app then declines to make.
        let own = settledRange(around: range, in: string)
        guard location < own.location || location > NSMaxRange(own) else { return nil }
        return (location, y)
    }

    /// Where a paragraph is drawn, in this view's coordinates.
    private func paragraphRect(_ paragraph: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: paragraph,
            actualCharacterRange: nil
        )
        guard glyphs.length > 0 else { return nil }
        let origin = textContainerOrigin
        return layoutManager
            .boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The y a boundary sits at with no gap held open.
    ///
    /// Measured with the band removed, because the band is what moved the text
    /// in the first place: measuring through it and then rebuilding it there
    /// makes the gap chase its own effect down the page.
    private func settledBoundaryY(at location: Int) -> CGFloat? {
        guard let textStorage else { return nil }
        let string = textStorage.string as NSString
        let previousPaths = textContainer?.exclusionPaths ?? []
        if !previousPaths.isEmpty { textContainer?.exclusionPaths = [] }
        defer {
            if !previousPaths.isEmpty { textContainer?.exclusionPaths = previousPaths }
        }
        if location >= string.length {
            guard let last = paragraphRect(
                string.lineRange(for: NSRange(location: max(0, string.length - 1), length: 0))
            ) else { return nil }
            return last.maxY
        }
        let paragraph = string.lineRange(for: NSRange(location: location, length: 0))
        guard let rect = paragraphRect(paragraph) else { return nil }
        return location <= paragraph.location ? rect.minY : rect.maxY
    }

    /// Everywhere a picture would land back where it started.
    ///
    /// Its own line, plus any run of blank lines either side of it. A picture
    /// separated from the next paragraph by a blank line is already "above
    /// that paragraph", so a drop aimed into that blank space is not a move
    /// however it is measured.
    private func settledRange(around range: NSRange, in text: NSString) -> NSRange {
        var settled = text.lineRange(for: range)
        while settled.location > 0 {
            let previous = text.lineRange(
                for: NSRange(location: settled.location - 1, length: 0)
            )
            guard text.substring(with: previous)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { break }
            settled = NSRange(
                location: previous.location,
                length: NSMaxRange(settled) - previous.location
            )
        }
        while NSMaxRange(settled) < text.length {
            let next = text.lineRange(
                for: NSRange(location: NSMaxRange(settled), length: 0)
            )
            guard text.substring(with: next)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { break }
            settled = NSRange(
                location: settled.location,
                length: NSMaxRange(next) - settled.location
            )
        }
        return settled
    }

    /// Push everything below `y` down far enough to show the picture fitting.
    ///
    /// An exclusion path rather than an edit: the document must not be touched
    /// to preview a move that has not happened, and text flowing around a
    /// reserved rectangle is a thing the layout manager already knows how to
    /// do.
    private func openDropGap(atY y: CGFloat, height: CGFloat) {
        guard let textContainer, height > 1 else { return }
        let gap = NSRect(x: 0, y: y, width: max(textContainer.size.width, 1), height: height)
        if let current = dropGap, abs(current.minY - gap.minY) < 0.5 { return }
        dropGap = gap
        let origin = textContainerOrigin
        // Exclusion paths are in the container's own coordinates, where the
        // text runs from 0 to the container's width. Only the vertical offset
        // is converted: shifting x by the origin as well moved the band left by
        // the inset and left an uncovered strip of exactly that width down the
        // right-hand side, which the layout manager duly wrapped text into. A
        // band has to span the whole width or it is not a band.
        //
        // Widened by a point either side because the edges are compared in
        // floating point, and a line fragment that begins exactly on the
        // boundary is not reliably counted as overlapping it.
        let band = NSRect(
            x: -1,
            y: y - origin.y,
            width: textContainer.size.width + 2,
            height: height
        )
        textContainer.exclusionPaths = [NSBezierPath(rect: band)]
        dropLine.show(
            atY: y,
            from: origin.x,
            width: textContainer.size.width
        )
    }

    private func closeDropGap() {
        dropLine.show(atY: nil, from: 0, width: 0)
        guard dropGap != nil else { return }
        dropGap = nil
        textContainer?.exclusionPaths = []
    }

    /// The picture being carried, however the attachment happens to hold it.
    private func movingImage(in range: NSRange) -> NSImage? {
        guard let attachment = attachment(in: range) else { return nil }
        if let image = attachment.image { return image }
        return (attachment.attachmentCell as? NSTextAttachmentCell)?.image
    }

    private func endImageMove() {
        imageMoveRange = nil
        imageMoveOrigin = nil
        isMovingImage = false
        imageDropLocation = nil
        movingImageSize = nil
        closeDropGap()
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
