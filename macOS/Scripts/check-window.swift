// Does a real document window contain the rail it is showing?
//
// The geometry is unit-tested — `EditorPaneGeometry` answers how wide a window
// has to be and how narrow it may be dragged, and none of that needs a screen.
// What those tests cannot see is the wiring: whether the answer reaches the
// window. The bug this check exists for lived entirely in that gap. Every
// number was right and nothing asked the window to use them, so a document
// opened at the view's minimum width with the critique rail laid out past the
// trailing edge — header visible, body text and "Run critique" button outside
// the window.
//
// So this builds the real `MarkdownEditorView`, puts it in a real `NSWindow`
// the size a fresh document window is born, and reads the frame back.
//
// The window is fully transparent and ordered to the back, because the person
// who owns this machine is usually using it. It cannot be placed off-screen
// instead: a window that intersects no display has no `screen`, and the screen
// is half of what is being tested.
//
// Built by Scripts/run-window-checks.sh against the real app sources.

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

/// A real editor in a real window, of a given content width.
@MainActor
struct EditorWindow {
    let window: NSWindow
    let hosting: NSHostingView<MarkdownEditorView>

    init(contentWidth: CGFloat, documentURL: URL, text: String) {
        var document = MarkdownDocument(text: text)
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

        let frame = NSRect(x: 0, y: 0, width: contentWidth, height: 620)
        hosting = NSHostingView(rootView: view)
        hosting.frame = frame

        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        // On a real screen, because the screen is what growth is clamped
        // against — but invisible, and behind everything else.
        if let screen = NSScreen.main {
            window.setFrameOrigin(
                NSPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)
            )
        }
        window.alphaValue = 0
        window.orderBack(nil)
    }

    var contentWidth: CGFloat {
        window.contentRect(forFrameRect: window.frame).width
    }

    func settle(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default, before: Date().addingTimeInterval(0.02)
            )
        }
        hosting.layoutSubtreeIfNeeded()
    }

    /// The window's content, drawn.
    func draw() -> NSBitmapImageRep? {
        guard let rep = hosting.bitmapImageRepForCachingDisplay(
            in: hosting.bounds
        ) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    /// How much of the trailing `width` points is something other than the
    /// page's own paper.
    ///
    /// How the rail is found. It is ordinary SwiftUI and leaves no `NSView`
    /// behind, so a check that hunted the view tree for a 356-point subview
    /// reported it missing while it was on screen — the widths it could see
    /// were the scroll view's and the host's and nothing else.
    func trailingInk(width: CGFloat, of rep: NSBitmapImageRep) -> Int {
        let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
        let paper = EditorColorTheme(color: .blue, mode: .light)
            .editorBackgroundColor.usingColorSpace(.sRGB)!
        var ink = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(
                from: max(0, rep.pixelsWide - Int(width * scale)),
                to: rep.pixelsWide,
                by: 2
            ) {
                guard let colour = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                let difference =
                    abs(colour.redComponent - paper.redComponent)
                    + abs(colour.greenComponent - paper.greenComponent)
                    + abs(colour.blueComponent - paper.blueComponent)
                if difference > 0.12 { ink += 1 }
            }
        }
        return ink
    }

    /// Writes what was drawn, when the environment asks for it.
    func writePNG(_ rep: NSBitmapImageRep, named variable: String) {
        guard let path = ProcessInfo.processInfo.environment[variable]
        else { return }
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }
}

@main
@MainActor
enum Harness {
    /// What the app itself uses. Repeated here rather than read from `Layout`,
    /// which is internal to the view file, and a check that recomputed the
    /// numbers from the same source could not catch them changing.
    static let column: CGFloat = 700
    static let rail: CGFloat = 356
    static let columnMinimum: CGFloat = 360
    static let documentMinimum: CGFloat = 620

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = """
            # Understanding caching

            Caching is important because the cache stores data for later reads.
            When a request arrives the system looks in the cache first, and only
            falls through to the slower store when it finds nothing there.

            ## What goes wrong

            Invalidation is the hard part. A stale entry is worse than no entry,
            because the system is confident about something that stopped being
            true.

            """
        let documentURL = directory.appendingPathComponent("scroll-test.md")
        try? text.write(to: documentURL, atomically: true, encoding: .utf8)

        print("A window born too narrow for its comments")

        // 900 points: wider than the minimum, narrower than the pair, and the
        // width the reported bug was photographed at.
        let narrow = EditorWindow(
            contentWidth: 900, documentURL: documentURL, text: text
        )
        narrow.settle(for: 1.6)

        let wanted = EditorPaneGeometry.idealContentWidth(
            columnWidth: column, railWidth: rail, railIsOpen: true
        )
        check(
            "it is widened to hold the document and the whole rail",
            narrow.contentWidth >= wanted,
            "the window is \(narrow.contentWidth) points of content, "
                + "and needs \(wanted)"
        )
        check(
            "and no wider than that",
            narrow.contentWidth <= wanted,
            "it grew to \(narrow.contentWidth)"
        )
        check(
            "it is still on the screen it started on",
            NSScreen.main.map { $0.visibleFrame.intersects(narrow.window.frame) }
                ?? false,
            "the window is at \(narrow.window.frame)"
        )

        // The rail is really laid out in the room that was made for it, rather
        // than the window having been widened around an empty strip.
        if let rep = narrow.draw() {
            check(
                "and the rail is drawn in the room that was made for it",
                narrow.trailingInk(width: rail - 16, of: rep) > 500,
                "only \(narrow.trailingInk(width: rail - 16, of: rep)) points "
                    + "of rail ink in the trailing \(rail)"
            )
            narrow.writePNG(rep, named: "MDE_WINDOW_PNG")
        } else {
            check("the window can be drawn", false)
        }

        print("")
        print("How narrow it may then be dragged")

        check(
            "the floor rises to hold the rail while it is open",
            narrow.window.contentMinSize.width
                == EditorPaneGeometry.minimumContentWidth(
                    documentMinimum: documentMinimum,
                    columnMinimum: columnMinimum,
                    railWidth: rail,
                    railIsOpen: true,
                    screenWidth: NSScreen.main?.visibleFrame.width
                        ?? .greatestFiniteMagnitude
                ),
            "the window's minimum is \(narrow.window.contentMinSize.width)"
        )

        // Back to the width the bug was photographed at. The automatic sizing
        // covers the moment a window opens and nothing more, so this is the
        // half of the rule that has to hold afterwards: the column gives way
        // and the rail stays whole.
        narrow.window.setContentSize(NSSize(width: 900, height: 620))
        narrow.settle(for: 0.8)
        check(
            "dragged back to 900, the rail is still drawn whole",
            narrow.draw().map { narrow.trailingInk(width: rail - 16, of: $0) > 500 }
                ?? false,
            "the trailing \(rail) points are empty, so the rail was cut"
        )
        if let rep = narrow.draw() {
            narrow.writePNG(rep, named: "MDE_WINDOW_NARROW_PNG")
        }

        print("")
        print("A window that is already wide enough")

        let wide = EditorWindow(
            contentWidth: 1_400, documentURL: documentURL, text: text
        )
        let before = wide.window.frame
        wide.settle(for: 1.6)
        check(
            "is not narrowed to the ideal width",
            wide.contentWidth == 1_400,
            "it became \(wide.contentWidth)"
        )
        check(
            "and is not moved",
            wide.window.frame.origin == before.origin,
            "it moved from \(before.origin) to \(wide.window.frame.origin)"
        )

        print("")
        if failures == 0 {
            print("\(checks)/\(checks) checks passed")
            exit(0)
        }
        print("\(failures) of \(checks) checks failed")
        exit(1)
    }
}
