// Does a double-click on the title bar fill the screen, and does the next one
// put the window back?
//
// `TitleBarFill`'s tests prove the rules. This proves the wiring, which they
// cannot see: the real `WindowChromeDelegate` attached to a real window, sent
// double-clicks through `NSApplication.sendEvent`, so they reach the
// title-bar monitor the way the mouse's do. Then it reads where the window
// actually ended up.
//
// It does not move the mouse, and it works behind a locked screen. The window
// is fully transparent, is never made key, and is ordered to the back.
//
// Built by Scripts/run-title-bar-fill-checks.sh against the real app sources.

import AppKit
import MarkdownEditorUI

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

func same(_ a: NSRect, _ b: NSRect) -> Bool {
    abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2
        && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
}

/// A window that notes the mouse-downs that reach it rather than acting on
/// them: a double-click that got as far as the close button would close it.
///
/// Noted here rather than by a second event monitor, because AppKit does not
/// call its local monitors in a fixed order — measured, a monitor added later
/// ran first in seven runs of twelve — so a monitor cannot reliably see what
/// another one let through.
final class RecordingWindow: NSWindow {
    var received: NSEvent?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            received = event
            return
        }
        super.sendEvent(event)
    }
}

@main
@MainActor
enum Harness {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        guard let screen = NSScreen.main else {
            print("  FAIL there is no screen to fill")
            exit(1)
        }
        let available = screen.visibleFrame

        // The size a document opens at, somewhere in the middle of the screen,
        // so filling it has to grow it in every direction.
        let start = NSRect(
            x: available.minX + 60,
            y: available.minY + 40,
            width: min(900, available.width - 120),
            height: min(600, available.height - 80)
        )
        let window = RecordingWindow(
            contentRect: start,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.setFrame(start, display: false)
        window.orderBack(nil)

        let chrome = WindowChromeDelegate()
        chrome.attach(to: window)

        let original = window.frame

        /// The second mouse-down of a double-click, sent the way AppKit sends
        /// the mouse's: local monitors first, inside `sendEvent`, then the
        /// window. Returns what the chrome let through to the window, or nil
        /// if it took the click.
        func doubleClick(at point: NSPoint) -> NSEvent? {
            guard let event = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 2,
                pressure: 1
            ) else { return nil }
            window.received = nil
            application.sendEvent(event)
            return window.received
        }

        /// A point in the bar, well clear of the traffic lights, wherever the
        /// window is now. In window coordinates, which start at the bottom.
        func inBar() -> NSPoint {
            NSPoint(x: window.frame.width / 2, y: window.frame.height - 12)
        }

        print("Double-clicking the title bar")

        let taken = doubleClick(at: inBar())
        check("the title bar takes the double-click", taken == nil)
        check(
            "the first double-click fills all the available space",
            same(window.frame, available),
            "\(window.frame) against \(available)"
        )

        _ = doubleClick(at: inBar())
        check(
            "the second puts the window back where it was, at the size it was",
            same(window.frame, original),
            "\(window.frame) against \(original)"
        )

        _ = doubleClick(at: inBar())
        check(
            "the third fills it again",
            same(window.frame, available),
            "\(window.frame) against \(available)"
        )

        // Resized by hand while filled: the frame from before no longer
        // describes where the window is coming back from.
        let byHand = NSRect(
            x: available.minX + 20,
            y: available.minY + 20,
            width: 800,
            height: 560
        )
        window.setFrame(byHand, display: false)
        _ = doubleClick(at: inBar())
        check(
            "a window resized by hand after filling fills again",
            same(window.frame, available),
            "\(window.frame)"
        )
        _ = doubleClick(at: inBar())
        check(
            "and goes back to the size it was given by hand",
            same(window.frame, byHand),
            "\(window.frame) against \(byHand)"
        )

        print("Clicks that are not the title bar's")

        let before = window.frame
        if let close = window.standardWindowButton(.closeButton) {
            let onClose = close.convert(
                NSPoint(x: close.bounds.midX, y: close.bounds.midY),
                to: nil
            )
            let passed = doubleClick(at: onClose)
            check(
                "a double-click on a traffic light is left to the button",
                passed != nil && same(window.frame, before),
                "\(window.frame)"
            )
        } else {
            check("the window has a close button to aim at", false)
        }
        let passed = doubleClick(at: NSPoint(x: before.width / 2, y: 100))
        check(
            "a double-click in the document does not move the window",
            passed != nil && same(window.frame, before),
            "\(window.frame)"
        )

        print("Zoom keeps its own meaning")

        // The green button and Window ▸ Zoom still go to the best size for
        // the content — the document plus its comments — not the whole screen.
        chrome.contentWidth = 700
        window.setFrame(start, display: false)
        window.zoom(nil)
        check(
            "Zoom sizes the window to its content, at full height",
            abs(window.frame.width - window.frameRect(
                forContentRect: NSRect(x: 0, y: 0, width: 700, height: 100)
            ).width) <= 2
                && abs(window.frame.height - available.height) <= 2,
            "\(window.frame)"
        )

        window.orderOut(nil)
        print("\(checks - failures) of \(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
