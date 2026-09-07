import MarkdownEditorUI
import AppKit
import SwiftUI

/// The formatting controls, centred above the document.
///
/// Deliberately not a *thing*. It was an outlined block with a fill and a hard
/// drop — the same treatment as the notes and the header — and at the top of
/// the page that read as a slab of chrome competing with the writing. The
/// controls are the only part anybody needs to see, so what is left is the
/// icons, a hairline between groups, and nothing else: no frame, no fill, no
/// shadow. It sits on the page rather than on top of it.
///
/// The 8-bit treatment still belongs to the window's header and to the
/// critique pad, which are chrome. This is not.
struct FormattingBar: View {
    @ObservedObject var session: MarkdownEditorSession
    let colorTheme: EditorColorTheme

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            headingMenu
            separator
            group {
                button("Bold", "bold") { session.toggleInline(.bold) }
                button("Italic", "italic") { session.toggleInline(.italic) }
                button("Underline", "underline") { session.toggleInline(.underline) }
                button("Strikethrough", "strikethrough") {
                    session.toggleInline(.strikethrough)
                }
            }
            separator
            codeMenu
            separator
            group {
                button("Bulleted List", "list.bullet") { session.toggleList(.bulleted) }
                button("Numbered List", "list.number") { session.toggleList(.numbered) }
                button("Task List", "checklist") { session.toggleList(.task) }
                button("Quote", "text.quote") { session.toggleQuote() }
            }
            separator
            group {
                button("Link", "link") { session.chooseLink() }
                button("Horizontal Rule", "minus") { session.insertHorizontalRule() }
                button("Add Image", "photo.badge.plus") {
                    session.chooseAndInsertImage()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)

        // Fills the width it is given, hugs its own height.
        //
        // Both halves matter: a plain `fixedSize()` also pins the width, so
        // the bar stops spanning the column; leaving it off entirely lets the
        // bar grow to whatever vertical room the stack has, which drew it 286pt
        // tall with the icons stranded in the middle.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func group<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 0) { content() }
    }

    /// A hairline between groups. Short of full height, so it reads as a
    /// division rather than as a rule across something.
    private var separator: some View {
        Rectangle()
            .fill(PixelStyle.ink(colorTheme).opacity(0.16))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 7)
    }

    private func button(
        _ title: String,
        _ symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        PixelBarButton(
            title: title,
            symbol: symbol,
            colorTheme: colorTheme,
            action: action
        )
    }

    private var headingMenu: some View {
        Menu {
            Button("Paragraph") { session.applyHeading(level: 0) }
            Divider()
            ForEach(1...6, id: \.self) { level in
                Button("Heading \(level)") { session.applyHeading(level: level) }
            }
        } label: {
            Image(systemName: "textformat.size")
                .font(PixelBarButton.glyph)
                .foregroundStyle(PixelStyle.ink(colorTheme))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: PixelBarButton.side + 8, height: PixelBarButton.side)
        .foregroundStyle(PixelStyle.ink(colorTheme))

        .help("Paragraph and heading style")
    }

    private var codeMenu: some View {
        Menu {
            Button {
                session.toggleInline(.inlineCode)
            } label: {
                Label("Inline Code (Single Line)", systemImage: "curlybraces")
            }
            Button {
                session.insertFencedCodeBlock()
            } label: {
                Label("Fenced Code Block (Multi-Line)", systemImage: "terminal")
            }
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(PixelBarButton.glyph)
                .foregroundStyle(PixelStyle.ink(colorTheme))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: PixelBarButton.side + 8, height: PixelBarButton.side)
        .foregroundStyle(PixelStyle.ink(colorTheme))

        .help("Insert single-line or multi-line code")
    }
}

/// One control in the bar.
///
/// Hovering lays a faint square behind the glyph rather than inverting it. The
/// inverting block belongs to the header and the notes, where a control is
/// meant to look like a control; here the point is that nothing is visible
/// until you reach for it.
private struct PixelBarButton: View {
    static let side: CGFloat = 32
    /// SF Symbols, regular weight, at a size you can aim at.
    ///
    /// The system set rather than a bundled icon font: it is the only one
    /// carrying every mark this bar needs — strikethrough, a task list, a
    /// quote, a picture with a plus on it — in one weight and one optical
    /// family, and it costs no dependency.
    ///
    /// 12pt was sized for a bar that had a frame around it holding it
    /// together. Without the frame the icons *are* the bar, and they were too
    /// small to read as controls. Regular rather than bold: thirteen shouting
    /// icons are harder to pick one out of, not easier.
    static let glyph = Font.system(size: 15, weight: .regular)

    let title: String
    let symbol: String
    let colorTheme: EditorColorTheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Self.glyph)
                .frame(width: Self.side, height: Self.side)
                .foregroundStyle(PixelStyle.ink(colorTheme))
                .background(
                    PixelStyle.ink(colorTheme).opacity(isHovered ? 0.10 : 0)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(PointerShapeArea(cursor: .pointingHand))
        .onHover { inside in
            isHovered = inside
        }
        .help(title)
    }
}

/// Claims a pointer shape over whatever it is laid on, as a real cursor rect.
///
/// Setting the cursor from SwiftUI's `onHover` does not work here, and it took
/// a photograph of the screen to establish that: every icon showed an arrow
/// while the hover code was running correctly. Arriving on a button and leaving
/// the writing are separate tracking boundaries crossed by one movement, and
/// nothing orders the callbacks — so whatever `onHover` sets can be overwritten
/// immediately afterwards, by this app's own exit handling or by AppKit's.
///
/// A cursor rect is not in that race. AppKit resolves it from the pointer's
/// position through the same machinery that decides every other shape in the
/// window, which is why the pointing hand over a picture has always worked
/// while this did not. `hitTest` returns nil so the control underneath still
/// gets the click: cursor rects are registered per view and honoured whether or
/// not that view accepts mouse events.
private struct PointerShapeArea: NSViewRepresentable {
    final class Area: NSView {
        var cursor: NSCursor = .arrow

        /// Registered, and on its own not enough — see `cursorUpdate`.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
        }

        /// Ask to be told when the pointer needs a shape here.
        ///
        /// The cursor rect above is registered — `resetCursorRects` was
        /// instrumented and fires, with the right 32x32 bounds, in a window —
        /// and it is still not what decides the shape: with only the rect, the
        /// pointer photographed over every icon was the plain arrow. A tracking
        /// area owned by this view is delivered to `cursorUpdate` regardless,
        /// which is the same conclusion the editor reached for pictures.
        ///
        /// `.activeAlways` so it works in a window that is not key, and
        /// `.inVisibleRect` so the area stays the right size through every
        /// resize of the bar without being rebuilt.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        /// `cursorUpdate` only arrives when a boundary is crossed, and crossing
        /// into this one is exactly when the shape is wrong, so take both.
        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            cursor.set()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let cursor: NSCursor

    func makeNSView(context: Context) -> Area {
        let area = Area()
        area.cursor = cursor
        return area
    }

    func updateNSView(_ nsView: Area, context: Context) {
        nsView.cursor = cursor
        // The rect is the view's bounds, so it is wrong the moment the bar is
        // laid out again at a different size until AppKit is told to ask.
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}
