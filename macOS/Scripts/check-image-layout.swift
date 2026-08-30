// Runtime checks for where a picture is, using the real renderer.
//
// `Scripts/check-image-handles.swift` proves the arithmetic against AppKit
// with a hand-built attachment. That is necessary and not sufficient: what the
// pointer actually lands on depends on the attachment `RichMarkdownStyler`
// builds and the paragraph style it sets, and neither is reachable from a
// script or a test target.
//
// So this harness lays out a real rendered document, renders it to a bitmap,
// finds the picture by its pixels, and asserts that `imageRect(for:)` — the
// one function that decides what a click hits and where the handles go —
// agrees with where the picture actually is.
//
// Built by Scripts/run-image-layout-checks.sh against the real app sources.

import AppKit
import MarkdownEditorCore
import MarkdownEditorUI

@MainActor
private var failures = 0
@MainActor
private var checks = 0

@MainActor
func check(_ label: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if passed {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

/// The bounding box of the marker colour in a view, in the view's coordinates.
@MainActor
func drawnMarkerBounds(in view: NSView) -> CGRect? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        return nil
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            // Loose thresholds: the window's colour profile shifts the marker
            // on its way to the bitmap. Still unambiguous against the page.
            guard
                colour.redComponent > 0.7,
                colour.greenComponent < 0.6,
                colour.blueComponent > 0.7
            else { continue }
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    guard minX <= maxX, minY <= maxY else { return nil }
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    return CGRect(
        x: CGFloat(minX) / scale,
        y: CGFloat(minY) / scale,
        width: CGFloat(maxX - minX + 1) / scale,
        height: CGFloat(maxY - minY + 1) / scale
    )
}

@main
@MainActor
struct CheckImageLayout {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // A picture in a colour that appears nowhere in the theme.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mde-image-layout-\(UUID().uuidString)")
        let assets = directory.appendingPathComponent("Doc.assets")
        try? FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let pictureSize = NSSize(width: 240, height: 150)
        let swatch = NSImage(size: pictureSize)
        swatch.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        NSRect(origin: .zero, size: pictureSize).fill()
        swatch.unlockFocus()
        guard
            let tiff = swatch.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            print("could not build the fixture image")
            exit(1)
        }
        let pictureURL = assets.appendingPathComponent("photo.png")
        try? png.write(to: pictureURL)

        let documentURL = directory.appendingPathComponent("Doc.md")
        // A heading above it, so the line the picture sits on is not the first
        // and carries whatever spacing the styler gives a paragraph.
        let source = """
        # Heading

        Text before the picture, long enough that narrowing the pane rewraps \
        it onto more lines and pushes everything below it further down the page.

        ![photo](Doc.assets/photo.png)

        Text after.
        """
        try? source.write(to: documentURL, atomically: true, encoding: .utf8)

        let model = MarkdownRenderer.render(source)
        let attributed = RichMarkdownStyler.attributedString(
            for: model,
            documentURL: documentURL,
            colorTheme: EditorColorTheme(color: .blue, mode: .light)
        )

        let frame = NSRect(x: 0, y: 0, width: 700, height: 700)
        let textView = RichMarkdownTextView(frame: frame)
        // The same inset the app gives the rendered pane. Without it this view
        // has a text container origin of zero, and any bug whose size *is* the
        // inset simply cannot happen here: a drop-gap band that was shifted
        // left by the origin looked perfect in this check and wrapped text
        // down the right-hand side in the real app.
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.textContainer?.containerSize = NSSize(
            width: frame.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(attributed)

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: frame)
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        window.contentView = scrollView
        window.orderBack(nil)

        guard
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let storage = textView.textStorage
        else {
            print("no layout")
            exit(1)
        }
        layoutManager.ensureLayout(for: container)

        // Find the attachment the styler produced.
        var imageRange: NSRange?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if value is NSTextAttachment {
                imageRange = range
                stop.pointee = true
            }
        }

        print("Rendered image layout")
        guard let imageRange else {
            print("  FAIL the renderer produced no image attachment")
            exit(1)
        }

        guard let drawn = drawnMarkerBounds(in: textView) else {
            print("  FAIL the picture never drew — nothing to measure against")
            exit(1)
        }

        let attachment = storage.attribute(
            .attachment,
            at: imageRange.location,
            effectiveRange: nil
        ) as? NSTextAttachment

        guard let computed = textView.imageRect(for: imageRange) else {
            print("  FAIL imageRect(for:) returned nothing for the picture")
            exit(1)
        }

        // Reported for when this fails: the numbers are the diagnosis.
        print("       attachment bounds \(attachment?.bounds ?? .zero)")
        print("       drawn    \(drawn)")
        print("       computed \(computed)")

        check(
            "the computed size matches the drawn size",
            abs(computed.width - drawn.width) <= 1
                && abs(computed.height - drawn.height) <= 1,
            "computed \(computed.size), drawn \(drawn.size)"
        )

        check(
            "the computed origin matches the drawn origin",
            abs(computed.minX - drawn.minX) <= 1
                && abs(computed.minY - drawn.minY) <= 1,
            "computed \(computed.origin), drawn \(drawn.origin)"
        )

        // The whole point of the rect: a click has to land on the picture and
        // nowhere else. These are the four places a wrong rect shows up first.
        check(
            "the middle of the picture is inside the rect",
            computed.contains(CGPoint(x: drawn.midX, y: drawn.midY))
        )
        check(
            "just above the picture is outside the rect",
            !computed.contains(CGPoint(x: drawn.midX, y: drawn.minY - 3))
        )
        check(
            "just below the picture is outside the rect",
            !computed.contains(CGPoint(x: drawn.midX, y: drawn.maxY + 3))
        )
        check(
            "each corner of the picture is on the rect's corner",
            abs(computed.maxX - drawn.maxX) <= 1
                && abs(computed.maxY - drawn.maxY) <= 1
        )

        // And the click itself, through the real entry point.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let hit = textView.selectImageForChecking(
            at: CGPoint(x: drawn.midX, y: drawn.midY)
        )
        check("a click in the middle of the picture selects it", hit)
        check(
            "selecting the picture selects exactly one character",
            textView.selectedRange() == imageRange,
            "selected \(textView.selectedRange()), expected \(imageRange)"
        )

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let missAbove = textView.selectImageForChecking(
            at: CGPoint(x: drawn.midX, y: drawn.minY - 6)
        )
        check("a click above the picture does not select it", !missAbove)

        let missBeside = textView.selectImageForChecking(
            at: CGPoint(x: drawn.maxX + 40, y: drawn.midY)
        )
        check("a click beside the picture does not select it", !missBeside)

        // MARK: - Pointer shapes
        //
        // AppKit does not hand registered cursor rects back, so both views
        // report theirs through a function and register exactly that.

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        let unselected = textView.imageCursorRects()
        check(
            "the picture claims the pointer even when nothing is selected",
            unselected.count == 1,
            "\(unselected.count) rects"
        )
        check(
            "the pointer over the picture is an arrow, not an I-beam",
            unselected.first?.cursor === NSCursor.arrow,
            "cursor was \(String(describing: unselected.first?.cursor))"
        )
        check(
            "the arrow covers exactly the picture",
            unselected.first.map {
                abs($0.rect.minX - drawn.minX) <= 1 && abs($0.rect.minY - drawn.minY) <= 1
                    && abs($0.rect.maxX - drawn.maxX) <= 1 && abs($0.rect.maxY - drawn.maxY) <= 1
            } ?? false,
            "arrow rect \(unselected.first?.rect.debugDescription ?? "none") vs drawn \(drawn)"
        )

        // The rects above are only a source. What decides the shape on screen
        // is `pointerCursor`, because neither cursor rects on the text view nor
        // a view layered over it survive NSTextView re-asserting its I-beam —
        // both were measured on a real screen still showing an I-beam over a
        // picture at 0.96 confidence.
        check(
            "the pointer over a picture is the hand you pick things up with",
            textView.pointerCursor(at: NSPoint(x: drawn.midX, y: drawn.midY)) === NSCursor.pointingHand
        )
        check(
            "the pointer over plain text is still an I-beam",
            textView.pointerCursor(at: NSPoint(x: drawn.midX, y: drawn.maxY + 30)) === NSCursor.iBeam
        )
        check(
            "the pointer just outside a picture is not the hand",
            textView.pointerCursor(at: NSPoint(x: drawn.maxX + 20, y: drawn.midY)) !== NSCursor.pointingHand
        )

        // Order is load-bearing and invisible. These rects were once added
        // after `super.resetCursorRects()`, which claims the whole surface for
        // the I-beam, and the I-beam won — measured on a real screen at 0.96
        // confidence while every in-process check passed. The earlier claim is
        // the one AppKit keeps, so a picture must claim before the text view
        // claims everything. Nothing but reading the source catches a reorder.
        let textViewSource = (try? String(
            contentsOfFile: "Sources/MarkdownEditor/RichMarkdownTextView.swift",
            encoding: .utf8
        )) ?? ""
        let resetBody = textViewSource
            .components(separatedBy: "override func resetCursorRects() {")
            .dropFirst().first ?? ""
        let addsAt = resetBody.range(of: "addCursorRect")
        let superAt = resetBody.range(of: "super.resetCursorRects()")
        check(
            "a picture claims the pointer before the text view claims everything",
            addsAt != nil && superAt != nil && addsAt!.lowerBound < superAt!.lowerBound,
            "addCursorRect must come before super.resetCursorRects() in resetCursorRects"
        )

        // ── Reaching for a corner must not take the corner away ──────────
        //
        // A handle is centred *on* the picture's corner, so its outer half
        // lies outside the picture. Moving the pointer onto one therefore
        // leaves the picture, and if hover is defined as "over the picture"
        // the handles vanish at the very moment they are being reached for —
        // the resize cursor never appears at all.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        textView.updateHover(at: NSPoint(x: drawn.midX, y: drawn.midY))
        check(
            "hovering the picture shows the handles",
            textView.imageHandlesForChecking.isShowing
        )
        for (name, corner) in [
            ("top-left", NSPoint(x: drawn.minX, y: drawn.minY)),
            ("top-right", NSPoint(x: drawn.maxX, y: drawn.minY)),
            ("bottom-left", NSPoint(x: drawn.minX, y: drawn.maxY)),
            ("bottom-right", NSPoint(x: drawn.maxX, y: drawn.maxY)),
        ] {
            // A point just outside the picture, where the outer half of the
            // handle is drawn and where a hand reaching for it actually goes.
            let outward = NSPoint(
                x: corner.x + (corner.x > drawn.midX ? 3 : -3),
                y: corner.y + (corner.y > drawn.midY ? 3 : -3)
            )
            textView.updateHover(at: outward)
            check(
                "the handles survive reaching for the \(name) corner",
                textView.imageHandlesForChecking.isShowing
            )
            let cursor = textView.pointerCursor(at: outward)
            check(
                "the pointer on the \(name) corner is a resize cursor",
                cursor !== NSCursor.iBeam && cursor !== NSCursor.pointingHand
                    && cursor !== NSCursor.arrow,
                "got \(cursor)"
            )
            textView.updateHover(at: NSPoint(x: drawn.midX, y: drawn.midY))
        }
        textView.updateHover(at: nil)

        _ = textView.selectImageForChecking(at: CGPoint(x: drawn.midX, y: drawn.midY))
        let overlay = textView.imageHandlesForChecking
        let handleRects = overlay.cursorRects()
        check(
            "each corner handle claims the pointer",
            handleRects.count == 4,
            "\(handleRects.count) rects"
        )

        // A corner's shape has to match the diagonal it moves along, or the
        // pointer promises the wrong gesture before the drag starts. Stated
        // geometrically rather than by name: the two corners on one diagonal
        // must agree, and the two diagonals must differ. That holds however
        // the corners are named, and it is what a person actually sees.
        let overlayCentre = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        var byDiagonal: [Bool: [NSCursor]] = [:]
        for entry in handleRects {
            let dx = entry.rect.midX - overlayCentre.x
            let dy = entry.rect.midY - overlayCentre.y
            byDiagonal[dx * dy > 0, default: []].append(entry.cursor)
        }
        check(
            "the four handles sit two to a diagonal",
            byDiagonal.count == 2 && byDiagonal.values.allSatisfy { $0.count == 2 },
            "\(byDiagonal.mapValues(\.count))"
        )
        for (diagonal, cursors) in byDiagonal {
            check(
                "opposite corners on the \(diagonal ? "↘" : "↗") diagonal show the same pointer",
                cursors.count == 2 && cursors[0] === cursors[1]
            )
        }
        if let first = byDiagonal[true]?.first, let second = byDiagonal[false]?.first {
            check("the two diagonals show different pointers", first !== second)
        }

        // Each corner of the picture itself must land on exactly one handle.
        for (name, corner) in [
            ("top-left", NSPoint(x: drawn.minX, y: drawn.minY)),
            ("top-right", NSPoint(x: drawn.maxX, y: drawn.minY)),
            ("bottom-left", NSPoint(x: drawn.minX, y: drawn.maxY)),
            ("bottom-right", NSPoint(x: drawn.maxX, y: drawn.maxY)),
        ] {
            let local = overlay.convert(corner, from: textView)
            let claiming = handleRects.filter { $0.rect.contains(local) }
            check(
                "the picture's \(name) corner is a resize target",
                claiming.count == 1,
                "\(claiming.count) handles contain \(local)"
            )
        }

        // The middle of a selected picture is still the picture, not a handle.
        let middle = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        check(
            "the middle of a selected picture is not a resize target",
            !handleRects.contains { $0.rect.contains(middle) }
        )

        // ── Clicking a picture must focus the pane it is in. ──────────────
        //
        // `mouseDown` returns early on the image path, so `NSTextView` never
        // takes first responder by itself. Without it the resize is committed
        // against whichever pane *did* have focus — in Split view, the source
        // pane — and rewrites a different image or none at all.
        print("")
        print("Clicking a picture")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        window.makeFirstResponder(nil)
        check(
            "the rendered pane starts unfocused",
            window.firstResponder !== textView
        )
        let clickPoint = NSPoint(x: drawn.midX, y: drawn.midY)
        let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: textView.convert(clickPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let click {
            textView.mouseDown(with: click)
        }
        check(
            "clicking the picture selects it",
            textView.selectedRange() == imageRange,
            "\(textView.selectedRange()) vs \(imageRange)"
        )
        check(
            "clicking the picture focuses the pane it is in",
            window.firstResponder === textView
        )

        // ── Dragging a picture to somewhere else in the document ─────────
        //
        // A press on a picture has to stay a click until it has clearly become
        // a drag, or selecting a picture with a slightly unsteady hand would
        // silently rewrite the document.
        print("")
        print("Dragging a picture")

        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type,
                location: textView.convert(point, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        }

        var moved: (range: NSRange, destination: Int)?
        textView.moveImage = { range, destination in moved = (range, destination) }

        let grab = NSPoint(x: drawn.midX, y: drawn.midY)
        // Aimed at the exact middle of a word, measured from the layout rather
        // than guessed at with an offset. Every guess landed in a blank line or
        // past the end of a short one, where even a mid-word implementation
        // returns a line boundary and looks correct.
        let bodyText = (textView.textStorage?.string ?? "") as NSString
        let wordRange = bodyText.range(of: "pushes")
        var tail = NSPoint(x: drawn.midX, y: drawn.maxY + 40)
        if wordRange.location != NSNotFound,
           let lm = textView.layoutManager,
           let container = textView.textContainer {
            let glyphs = lm.glyphRange(forCharacterRange: wordRange, actualCharacterRange: nil)
            let wordRect = lm.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            tail = NSPoint(x: wordRect.midX, y: wordRect.midY)
        }

        // A press that barely moves is a click.
        moved = nil
        if let d = mouse(.leftMouseDown, grab) { textView.mouseDown(with: d) }
        if let m = mouse(.leftMouseDragged, NSPoint(x: grab.x + 2, y: grab.y + 1)) {
            textView.mouseDragged(with: m)
        }
        check("a two-point wobble is not a drag", !textView.isMovingImage)
        if let u = mouse(.leftMouseUp, NSPoint(x: grab.x + 2, y: grab.y + 1)) {
            textView.mouseUp(with: u)
        }
        check("a wobble does not move the picture", moved == nil)

        // A press that travels is a drag.
        moved = nil
        if let d = mouse(.leftMouseDown, grab) { textView.mouseDown(with: d) }
        if let m = mouse(.leftMouseDragged, tail) { textView.mouseDragged(with: m) }
        check("dragging away from the picture starts a move", textView.isMovingImage)
        check(
            "a drop point is offered",
            textView.imageDropLocation != nil,
            "\(String(describing: textView.imageDropLocation))"
        )
        if let drop = textView.imageDropLocation {
            check(
                "the drop point is outside the picture's own text",
                drop < imageRange.location || drop > NSMaxRange(imageRange),
                "drop \(drop) vs image \(imageRange)"
            )
            check(
                "the drop line has somewhere to be drawn",
                (textView.dropBoundary(
                    for: tail,
                    moving: imageRange
                )?.y ?? 0) > 0
            )
            check(
                "a gap is held open for the picture",
                (textView.dropGap?.height ?? 0) > 1,
                "gap \(String(describing: textView.dropGap))"
            )
        }

        // The gap must push the text below it down, not part it and flow
        // alongside. An exclusion band that does not span the full width leaves
        // a strip the layout manager will happily wrap into, and the picture
        // then looks like it is being inset into the paragraph rather than
        // dropped between two lines. Ask the layout where every line actually
        // is and require the band to be empty.
        if let gap = textView.dropGap,
           let lm = textView.layoutManager,
           let container = textView.textContainer {
            let origin = textView.textContainerOrigin
            var intruder: NSRect?
            var glyph = 0
            while glyph < lm.numberOfGlyphs {
                var effective = NSRange()
                let fragment = lm
                    .lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
                    .offsetBy(dx: origin.x, dy: origin.y)
                if fragment.intersects(gap.insetBy(dx: 0, dy: 1)) {
                    intruder = fragment
                    break
                }
                glyph = max(NSMaxRange(effective), glyph + 1)
            }
            check(
                "no line of text sits beside the gap",
                intruder == nil,
                "line \(intruder.map { NSStringFromRect($0) } ?? "none") overlaps gap \(NSStringFromRect(gap))"
            )
            check(
                "the gap spans the whole text column",
                container.exclusionPaths.first.map {
                    $0.bounds.minX <= 0 && $0.bounds.maxX >= container.size.width
                } ?? false,
                "band \(container.exclusionPaths.first.map { NSStringFromRect($0.bounds) } ?? "none") vs width \(container.size.width)"
            )
        }
        // The whole point of the change: a drop lands *between* lines. If this
        // ever reports a character in the middle of a word again, the document
        // gets `Ome![photo](a.png)ga paragraph.` back.
        if let drop = textView.imageDropLocation, let storage = textView.textStorage {
            let text = storage.string as NSString
            let atStart = drop == 0
            let atEnd = drop >= text.length
            let afterNewline = drop > 0 && text.character(at: drop - 1) == 0x0A
            let beforeNewline = drop < text.length && text.character(at: drop) == 0x0A
            check(
                "the drop point is a line boundary, never mid-word",
                atStart || atEnd || afterNewline || beforeNewline,
                "drop \(drop) sits inside \(text.substring(with: NSRange(location: max(0, drop - 4), length: min(8, text.length - max(0, drop - 4)))).debugDescription)"
            )
        }

        let expected = textView.imageDropLocation
        if let u = mouse(.leftMouseUp, tail) { textView.mouseUp(with: u) }
        check("releasing asks for the move", moved != nil)
        check(
            "it asks to move the picture that was grabbed",
            moved?.range == imageRange,
            "\(String(describing: moved?.range)) vs \(imageRange)"
        )
        check(
            "it asks for the point the caret was showing",
            moved?.destination == expected,
            "\(String(describing: moved?.destination)) vs \(String(describing: expected))"
        )
        check("the drag is over once released", !textView.isMovingImage)

        // Dropping a picture back on itself is not a move.
        moved = nil
        if let d = mouse(.leftMouseDown, grab) { textView.mouseDown(with: d) }
        if let m = mouse(.leftMouseDragged, NSPoint(x: grab.x + 12, y: grab.y + 8)) {
            textView.mouseDragged(with: m)
        }
        check(
            "there is no drop point inside the picture itself",
            textView.imageDropLocation == nil,
            "\(String(describing: textView.imageDropLocation))"
        )
        if let u = mouse(.leftMouseUp, NSPoint(x: grab.x + 12, y: grab.y + 8)) {
            textView.mouseUp(with: u)
        }
        check("dropping a picture on itself does not move it", moved == nil)

        // An indicator is a promise. Anywhere the app draws the rule and holds
        // the gap open, releasing must actually move the picture — otherwise it
        // shows a landing place and then declines to use it. The blank line
        // just below a picture is the case that got this wrong: it is outside
        // the picture's own line but still exactly where the picture already
        // sits, so a drop there was advertised and then refused.
        var promisedButRefused: [CGFloat] = []
        for step in stride(from: drawn.minY - 60, through: drawn.maxY + 60, by: 6) {
            let probe = NSPoint(x: drawn.midX, y: step)
            guard let boundary = textView.dropBoundary(for: probe, moving: imageRange) else {
                continue
            }
            // Worked out here rather than asked of the view, so this measures
            // the app against the definition instead of against itself.
            if let text = textView.textStorage?.string as NSString? {
                var settled = text.lineRange(for: imageRange)
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
                if boundary.location >= settled.location,
                   boundary.location <= NSMaxRange(settled) {
                    promisedButRefused.append(step)
                }
            }
        }
        check(
            "every place the app offers a drop is a place it will really move to",
            promisedButRefused.isEmpty,
            "offered a no-op drop at y \(promisedButRefused.map { String(format: "%.0f", $0) }.joined(separator: ", "))"
        )
        textView.moveImage = nil
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()

        // ── Reflow must carry the handles with the picture. ───────────────
        //
        // Re-wrapping the text above an image moves it without changing the
        // selection or the document, so nothing else repositions the overlay.
        // Stale handles are still the live drag target, over blank text.
        print("")
        print("Reflowing under a selected picture")
        textView.setSelectedRange(imageRange)
        textView.updateImageHandles()
        let liveOverlay = textView.imageHandlesForChecking
        let frameBeforeReflow = liveOverlay.frame
        let narrower = NSRect(x: 0, y: 0, width: 420, height: 700)
        textView.textContainer?.containerSize = NSSize(
            width: narrower.width,
            height: .greatestFiniteMagnitude
        )
        textView.setFrameSize(narrower.size)
        layoutManager.ensureLayout(for: container)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let reflowed = textView.imageRect(for: imageRange)
        check(
            "the picture really did move when the pane narrowed",
            reflowed.map { abs($0.minX - drawn.minX) > 1 || abs($0.minY - drawn.minY) > 1 } ?? false,
            "\(String(describing: reflowed)) vs \(drawn)"
        )
        if let reflowed {
            check(
                "the handles followed the picture",
                abs(liveOverlay.frame.midX - reflowed.midX) < 2
                    && abs(liveOverlay.frame.midY - reflowed.midY) < 2,
                "overlay \(liveOverlay.frame) vs picture \(reflowed)"
            )
            check(
                "the handles did not stay where they were",
                abs(liveOverlay.frame.minX - frameBeforeReflow.minX) > 1
                    || abs(liveOverlay.frame.minY - frameBeforeReflow.minY) > 1,
                "still \(liveOverlay.frame)"
            )
        }

        // ── A refused resize must leave the picture matching the text. ────
        //
        // A drag previews by changing the attachment's bounds and nothing
        // else. If the commit is refused, only a re-render would put it back —
        // and a refused commit is exactly the case that does not re-render.
        print("")
        print("A resize that is refused")
        guard let previewed = textView.attachmentForChecking(in: imageRange) else {
            print("  FAIL no attachment to preview")
            exit(1)
        }
        let documentBounds = previewed.bounds
        var committed = false
        textView.commitImageSize = { _, _ in committed = true }
        textView.previewImageSizeForChecking(
            MarkdownImageTag.Size(width: Int(documentBounds.width) + 120, height: nil)
        )
        check(
            "the drag really did change the drawn size",
            abs(previewed.bounds.width - documentBounds.width) > 1,
            "\(previewed.bounds.width) vs \(documentBounds.width)"
        )
        textView.commitImageSizeForChecking(
            MarkdownImageTag.Size(width: Int(documentBounds.width) + 120, height: nil)
        )
        check("the commit was still delivered", committed)
        check(
            "a refused resize puts the picture back at the document's size",
            abs(previewed.bounds.width - documentBounds.width) < 0.5,
            "\(previewed.bounds.width) vs \(documentBounds.width)"
        )

        // ── The drag cursor must not outlive the view. ────────────────────
        //
        // `NSCursor`'s stack is process-wide, so a push stranded by a window
        // closing mid-drag leaves the diagonal arrow over every other app.
        print("")
        print("A drag interrupted by teardown")
        let before = NSCursor.current
        liveOverlay.beginDragForChecking(at: .topLeading)
        check("the drag pushed a cursor", NSCursor.current !== before)
        liveOverlay.removeFromSuperview()
        check(
            "leaving the window pops it again",
            NSCursor.current === before,
            "\(String(describing: NSCursor.current))"
        )

        print("")
        if failures == 0 {
            print("ALL PASS (\(checks) checks)")
            exit(0)
        }
        print("\(failures) of \(checks) checks failed")
        exit(1)
    }
}
