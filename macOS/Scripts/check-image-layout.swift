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
