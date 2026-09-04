import AppKit
import SwiftUI

/// Claims the arrow cursor over the area it covers.
///
/// A real cursor rect, because nothing else works here. `NSCursor.arrow.set()`
/// and `push()`/`pop()` from a SwiftUI `onHover` both lose: `NSTextView`
/// registers a single I-beam over its whole surface in `resetCursorRects`, and
/// AppKit re-applies cursor rects on mouse-moved, so whatever was set a moment
/// ago is replaced before the pointer has finished arriving.
///
/// The same lesson is written up in `RichMarkdownTextView.imageCursorRects` for
/// the resize corners, where a tracking area asking for `cursorUpdate` was
/// measured arriving 6 times across 99 mouse moves. Cursor rects are the only
/// mechanism that holds.
///
/// Used as a `.background`, so it never takes a click off the control in front
/// of it — a cursor rect is geometric and does not need to be hit-testable.
struct ArrowCursorArea: NSViewRepresentable {
    final class Area: NSView {
        /// Separate from `resetCursorRects` so a check can read it directly.
        /// AppKit gives no way to ask what rects a view registered.
        func cursorRects() -> [(rect: NSRect, cursor: NSCursor)] {
            [(bounds, NSCursor.arrow)]
        }

        override func resetCursorRects() {
            for entry in cursorRects() {
                addCursorRect(entry.rect, cursor: entry.cursor)
            }
        }

        /// The window caches cursor rects, so one laid out at a new size keeps
        /// the old one until it is told.
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }

    func makeNSView(context: Context) -> Area { Area() }

    func updateNSView(_ view: Area, context: Context) {
        view.window?.invalidateCursorRects(for: view)
    }
}
