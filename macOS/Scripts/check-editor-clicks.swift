// Can a picture in a real editor window actually be clicked?
//
// `check-image-layout` proves the geometry: where the picture is, which rects
// answer the pointer, what a click on the text view does. It builds the text
// view directly, which is precisely what makes it blind to the failure a
// person actually reports. The app does not show a bare text view. It shows a
// SwiftUI hierarchy with a floating file explorer, a centred preview column, a
// width gripper and a toolbar layered around it, and any one of those could sit
// over the picture and swallow the click while every geometry check still
// passes.
//
// So this builds the real `MarkdownEditorView`, hosts it, opens a document off
// disk, and asks the window the same question the mouse asks: at the point
// where the picture is drawn, which view is going to receive the click?
//
// The window is positioned off-screen and never ordered front, because the
// person who owns this machine is usually using it.
//
// Built by Scripts/run-editor-click-checks.sh against the real app sources.

import AppKit
import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

@MainActor
private var failures = 0
@MainActor
private var checks = 0

@MainActor
func check(
    _ label: String,
    _ passed: Bool,
    _ detail: @autoclosure () -> String = ""
) {
    checks += 1
    if passed {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

/// Every view under `root`, deepest last.
@MainActor
func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
func firstTextView(under root: NSView) -> RichMarkdownTextView? {
    descendants(of: root).compactMap { $0 as? RichMarkdownTextView }.first
}

@main
@MainActor
enum Harness {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let images = directory.appendingPathComponent("images", isDirectory: true)
        let posts = directory.appendingPathComponent("posts", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: images,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: posts,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // 2:1, so the drawn shape tells the real picture from the placeholder.
        guard let png = makePNG(width: 120, height: 60) else {
            print("could not build the fixture image")
            exit(1)
        }
        try? png.write(to: images.appendingPathComponent("photo.png"))

        // Kept one level up from the document, the layout that silently drew a
        // placeholder until the read path stopped enforcing the write rule.
        let source = """
        # Existing document

        Text before the picture.

        ![photo](../images/photo.png)

        Text after.
        """
        let documentURL = posts.appendingPathComponent("article.md")
        try? source.write(to: documentURL, atomically: true, encoding: .utf8)

        var document = MarkdownDocument(text: source)
        var themeColor = EditorThemeColor.blue.rawValue
        var appearance = EditorAppearanceMode.light.rawValue

        let view = MarkdownEditorView(
            document: Binding(get: { document }, set: { document = $0 }),
            fileURL: documentURL,
            themeColorRawValue: Binding(
                get: { themeColor },
                set: { themeColor = $0 }
            ),
            appearanceModeRawValue: Binding(
                get: { appearance },
                set: { appearance = $0 }
            )
        )

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame

        // Far off any real display, and never ordered front. The window has to
        // exist — SwiftUI will not lay out or build AppKit-backed children
        // without one — but it must never appear in front of somebody's work.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        window.orderBack(nil)

        settle(for: 1.2)
        hosting.layoutSubtreeIfNeeded()
        settle(for: 0.6)

        print("A picture in a real editor window")

        guard let textView = firstTextView(under: hosting) else {
            print("  FAIL the rendered pane never appeared in the hierarchy")
            exit(1)
        }
        check("the rendered pane is in the real view hierarchy", true)

        guard
            let storage = textView.textStorage,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            print("  FAIL the rendered pane has no text system")
            exit(1)
        }
        layoutManager.ensureLayout(for: container)

        var imageRange: NSRange?
        var attachment: NSTextAttachment?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, stop in
            if let found = value as? NSTextAttachment {
                imageRange = range
                attachment = found
                stop.pointee = true
            }
        }

        guard let imageRange, let attachment else {
            print("  FAIL the document rendered no picture at all")
            exit(1)
        }
        check("the document rendered a picture", true)

        // The reader's picture, not the fallback symbol.
        let size = attachment.bounds.size
        check(
            "the picture drawn is the file on disk, not the placeholder",
            size.width > 0 && size.height > 0
                && abs(size.width / size.height - 2) < 0.05,
            "drawn \(size), which is not the fixture's 2:1"
        )

        guard let picture = textView.imageRect(for: imageRange) else {
            print("  FAIL the picture has no rectangle")
            exit(1)
        }

        // ── The question a mouse asks ────────────────────────────────────
        //
        // hitTest runs the whole hierarchy, so anything floating over the
        // preview — the explorer, the gripper, a spacer with a background —
        // shows up here and nowhere else.
        let centreInWindow = textView.convert(
            NSPoint(x: picture.midX, y: picture.midY),
            to: nil
        )
        // `hitTest` takes a point in the receiver's *superview* system. For a
        // content view that is the window's own coordinates, so this must not
        // be converted first — converting double-counts the title bar, which a
        // large target survives and a 15 pt corner handle does not.
        let hit = hosting.hitTest(centreInWindow)
        let reachesTextView = hit === textView
            || (hit.map { descendants(of: textView).contains($0) } ?? false)
        check(
            "a click on the picture reaches the rendered pane",
            reachesTextView,
            "it would go to \(hit.map { String(describing: type(of: $0)) } ?? "nothing")"
        )

        // ── The pointer, before anything has been clicked ────────────────
        //
        // This is how a picture is actually met: open a document, move the
        // pointer onto it. No selection, no click, no scroll. Measured on a
        // real screen the app got this wrong while showing the right pointer
        // once the picture had been selected, so the unclicked case is the one
        // worth pinning down.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        check(
            "the pointer over an untouched picture is the hand you pick things up with",
            textView.pointerCursor(at: NSPoint(x: picture.midX, y: picture.midY)) === NSCursor.pointingHand,
            "got \(textView.pointerCursor(at: NSPoint(x: picture.midX, y: picture.midY)))"
        )
        check(
            "the pointer over text beneath it is an I-beam",
            textView.pointerCursor(at: NSPoint(x: picture.midX, y: picture.maxY + 30)) === NSCursor.iBeam
        )

        // ── Hovering must reveal the handles, without a click ────────────
        //
        // The frame used to appear only once a picture had been clicked, so
        // the thing telling you a picture can be resized only appeared after
        // you had already guessed it could.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        textView.updateHover(at: nil)
        check(
            "nothing is framed before the pointer arrives",
            textView.imageHandlesForChecking.isHidden
        )
        textView.updateHover(at: NSPoint(x: picture.midX, y: picture.midY))
        check(
            "hovering a picture shows the resize frame",
            textView.imageHandlesForChecking.isShowing
        )
        check(
            "hovering a picture offers all four corners",
            textView.imageHandlesForChecking.cursorRects().count == 4
        )
        check(
            "the corners are diagonal resize pointers on hover",
            textView.pointerCursor(at: NSPoint(x: picture.minX, y: picture.minY))
                !== NSCursor.pointingHand
        )
        textView.updateHover(at: NSPoint(x: picture.midX, y: picture.maxY + 40))
        check(
            "moving off the picture takes the frame away again",
            textView.imageHandlesForChecking.isHidden
        )

        // ── The click itself, through the real window ────────────────────
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.updateImageHandles()
        window.makeFirstResponder(nil)

        if let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: centreInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) {
            textView.mouseDown(with: event)
        }
        settle(for: 0.3)

        check(
            "clicking the picture selects it",
            textView.selectedRange() == imageRange,
            "\(textView.selectedRange()) vs \(imageRange)"
        )
        check(
            "clicking the picture focuses the pane it is in",
            window.firstResponder === textView
        )

        let overlay = textView.imageHandlesForChecking
        check("the resize frame is showing", !overlay.isHidden)
        check(
            "the frame is around the picture",
            abs(overlay.frame.midX - picture.midX) < 2
                && abs(overlay.frame.midY - picture.midY) < 2,
            "frame \(overlay.frame) vs picture \(picture)"
        )

        // ── A corner must reach the handle, not the text ─────────────────
        let corner = textView.convert(
            NSPoint(x: picture.minX, y: picture.minY),
            to: nil
        )
        let cornerHit = hosting.hitTest(corner)
        check(
            "a click on a corner reaches the resize handle",
            cornerHit === overlay,
            "it would go to \(cornerHit.map { String(describing: type(of: $0)) } ?? "nothing")"
        )

        // ── And ordinary text still behaves like text ────────────────────
        let belowPicture = textView.convert(
            NSPoint(x: picture.midX, y: picture.maxY + 40),
            to: nil
        )
        let textHit = hosting.hitTest(belowPicture)
        check(
            "a click below the picture still reaches the text",
            textHit === textView
                || (textHit.map { descendants(of: textView).contains($0) } ?? false),
            "it would go to \(textHit.map { String(describing: type(of: $0)) } ?? "nothing")"
        )

        print("")
        if failures == 0 {
            print("ALL PASS (\(checks) checks)")
            exit(0)
        }
        print("\(failures) of \(checks) checks failed")
        exit(1)
    }

    /// SwiftUI builds its AppKit children on later run-loop passes, so the
    /// hierarchy does not exist immediately after hosting.
    private static func settle(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func makePNG(width: Int, height: Int) -> Data? {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
