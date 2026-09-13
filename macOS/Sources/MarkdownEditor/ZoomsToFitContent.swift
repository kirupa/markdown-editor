import AppKit
import MarkdownEditorUI
import SwiftUI

/// Makes the green button and a double-click on the title bar size the window
/// to the thing it is showing.
///
/// macOS asks the window's delegate `windowWillUseStandardFrame(_:defaultFrame:)`
/// and, with no answer, offers the whole screen. That is the wrong answer here
/// twice over: it is far more window than a document column needs, and with the
/// comments open it does not follow the content at all — the rail is a fixed
/// width docked to the document, so "everything" is a specific number rather
/// than "as much as possible".
///
/// Attached as a modifier on the editor, which is the only place that knows the
/// column's current width and whether the comments are open.
struct ZoomsToFitContent: ViewModifier {
    let contentWidth: CGFloat

    func body(content: Content) -> some View {
        content.background(WindowZoomTarget(contentWidth: contentWidth))
    }
}

extension View {
    /// Zoom this window to `contentWidth` points of content.
    func zoomsToFitContent(_ contentWidth: CGFloat) -> some View {
        modifier(ZoomsToFitContent(contentWidth: contentWidth))
    }
}

/// The bridge to the window. Draws nothing.
private struct WindowZoomTarget: NSViewRepresentable {
    let contentWidth: CGFloat

    func makeCoordinator() -> ZoomDelegate { ZoomDelegate() }

    func makeNSView(context: Context) -> NSView {
        let view = AttachingView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.contentWidth = contentWidth
        // The window may arrive after the first layout pass, so this is also
        // where a late one gets picked up.
        (nsView as? AttachingView)?.attachIfPossible()
    }

    /// A view whose only job is to notice it has a window.
    final class AttachingView: NSView {
        weak var coordinator: ZoomDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfPossible()
        }

        func attachIfPossible() {
            guard let window, let coordinator else { return }
            coordinator.attach(to: window)
        }
    }
}

/// Answers the zoom question, and passes every other question along.
///
/// A window has one delegate and SwiftUI's `DocumentGroup` has already claimed
/// it — for window restoration, for the document's edited state, for the close
/// behaviour. Replacing it outright would break all of that silently, so this
/// stands in front and forwards everything it does not answer itself, through
/// the ordinary Objective-C forwarding that `NSWindow` uses to ask in the first
/// place.
final class ZoomDelegate: NSObject, NSWindowDelegate {
    var contentWidth: CGFloat = 0

    /// The delegate that was there first. Strong on purpose: `window.delegate`
    /// is a weak reference, so once this object takes that slot nothing else
    /// holds SwiftUI's delegate and it would be deallocated — taking window
    /// restoration and the document's close handling with it.
    private var next: NSWindowDelegate?
    private weak var window: NSWindow?

    func attach(to window: NSWindow) {
        // Idempotent: `viewDidMoveToWindow` and `updateNSView` both call this,
        // and a second attach would make this object its own `next` and
        // forward to itself for ever.
        guard window.delegate !== self else { return }
        self.window = window
        next = window.delegate
        window.delegate = self
        watchForDoubleClicks()
    }

    // MARK: - Double-clicking the title bar

    private var monitor: Any?

    /// Zoom on a double-click in the title bar, because the system will not.
    ///
    /// macOS only sends `zoom:` from a title-bar double-click when "Double-click
    /// a window's title bar to" is set to Zoom. Measured on this machine it is
    /// not — `AppleMiniaturizeOnDoubleClick` is 0 and `AppleActionOnDoubleClick`
    /// is unset, so the gesture does nothing at all, in every app. The delegate
    /// above is still the right thing and still answers the green button and
    /// Window ▸ Zoom; this is what makes the gesture itself arrive.
    ///
    /// A *local* monitor, so it only ever sees this app's own events.
    private func watchForDoubleClicks() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            self?.zoomIfTitleBarDoubleClick(event)
            // Returned unchanged: this reads the event, it does not consume it.
            // Swallowing it would break dragging the window by its title bar,
            // which is the same gesture minus the second click.
            return event
        }
    }

    private func zoomIfTitleBarDoubleClick(_ event: NSEvent) {
        guard event.clickCount == 2,
              let window, event.window === window,
              // The title bar's own view, found through a button AppKit always
              // puts there.
              let titleBar = window.standardWindowButton(.closeButton)?.superview
        else { return }

        guard EditorPaneGeometry.titleBarClickZooms(
            at: event.locationInWindow,
            titleBar: titleBar.convert(titleBar.bounds, to: nil),
            controls: controlFrames(in: window)
        ) else { return }
        window.zoom(nil)
    }

    /// Whether something clickable sits under this point in the title bar.
    ///
    /// Asked of the controls' own frames rather than by hit-testing, which
    /// cannot answer it here: SwiftUI draws the whole bar through one
    /// `ToolbarItemHostingView`, so a hit test at the theme button, at the
    /// document's title and at empty space away from both all return the same
    /// view. Measured — the first version trusted the hit test and zoomed the
    /// window every time the theme button was double-clicked.
    ///
    /// The title text is deliberately not counted. It is not a control, and
    /// double-clicking it zooms in every other Mac application.
    private func controlFrames(in window: NSWindow) -> [CGRect] {
        var frames: [CGRect] = []
        for item in window.toolbar?.items ?? [] {
            guard let view = item.view else { continue }
            frames.append(view.convert(view.bounds, to: nil))
        }
        // The traffic lights, which are the window's rather than the toolbar's.
        let standard: [NSWindow.ButtonType] = [
            .closeButton, .miniaturizeButton, .zoomButton,
            .toolbarButton, .documentIconButton, .fullScreenButton,
        ]
        for kind in standard {
            guard let button = window.standardWindowButton(kind) else { continue }
            frames.append(button.convert(button.bounds, to: nil))
        }
        return frames
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: - The one question this answers

    func windowWillUseStandardFrame(
        _ window: NSWindow,
        defaultFrame: NSRect
    ) -> NSRect {
        guard contentWidth > 0 else { return defaultFrame }

        // Content points to window points: the difference is the window's own
        // frame, which is not a constant — a title bar's height depends on
        // whether the window has a toolbar, and on the system's text size.
        let asFrame = window.frameRect(
            forContentRect: NSRect(
                x: 0, y: 0, width: contentWidth, height: 100
            )
        )
        let width = min(asFrame.width, defaultFrame.width)

        // Full height, which is what zoom means vertically: a document is as
        // long as it is, so there is no height that "fits the content".
        //
        // Horizontally the window stays where it is unless that would push it
        // off the screen, because zoom is a resize and a window that jumps
        // across the desk to grow is disorienting.
        let x = min(
            max(window.frame.minX, defaultFrame.minX),
            defaultFrame.maxX - width
        )
        return NSRect(
            x: x,
            y: defaultFrame.minY,
            width: width,
            height: defaultFrame.height
        )
    }

    // MARK: - Everything else

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return next?.responds(to: selector) ?? false
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if next?.responds(to: selector) == true { return next }
        return super.forwardingTarget(for: selector)
    }
}
