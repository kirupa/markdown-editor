import MarkdownEditorUI
import SwiftUI

/// The formatting controls, as one block the width of the document.
///
/// It sits above the column and spans it exactly, rather than floating in the
/// window's title bar. That ties the controls to the thing they act on: the
/// bar and the document share an edge, so it reads as this document's
/// formatting rather than the application's. The controls themselves are
/// centred within it.
///
/// The look is the reference designs' rather than the platform's: a two point
/// edge, a solid drop with no blur in it, square corners, and the theme's own
/// tint as the fill. Nothing here is a rounded rectangle and nothing fades.
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
        .padding(3)
        .background(
            ZStack {
                Rectangle()
                    .fill(PixelStyle.hardShadow(colorTheme))
                    .offset(
                        x: PixelStyle.shadowOffset,
                        y: PixelStyle.shadowOffset
                    )
                Rectangle().fill(PixelStyle.barSurface(colorTheme))
                Rectangle()
                    .strokeBorder(
                        PixelStyle.ink(colorTheme),
                        lineWidth: PixelStyle.boldBorder
                    )
            }
        )
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

    private var separator: some View {
        Rectangle()
            .fill(PixelStyle.ink(colorTheme))
            .frame(width: PixelStyle.boldBorder)
            .padding(.vertical, 1)
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
        .frame(width: PixelBarButton.side + 6, height: PixelBarButton.side)
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
        .frame(width: PixelBarButton.side + 6, height: PixelBarButton.side)
        .foregroundStyle(PixelStyle.ink(colorTheme))
        .help("Insert single-line or multi-line code")
    }
}

/// One square control in the bar.
///
/// Hovering fills the whole square and flips the glyph to the paper colour,
/// rather than tinting it or rounding a highlight behind it. A block that
/// inverts is the 8-bit way of saying "this is the one under the pointer", and
/// it is legible on every one of the sixteen themes without a per-theme
/// highlight colour.
private struct PixelBarButton: View {
    static let side: CGFloat = 26
    /// Regular, not bold.
    ///
    /// The weight in this design belongs to the frame: a heavy edge with a
    /// hard drop. Emboldening the glyphs as well made the inside of the block
    /// as loud as its outline, and a row of thirteen shouting icons is harder
    /// to pick a single control out of, not easier.
    static let glyph = Font.system(size: 12, weight: .regular)

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
                .foregroundStyle(
                    isHovered
                        ? PixelStyle.barSurface(colorTheme)
                        : PixelStyle.ink(colorTheme)
                )
                .background(
                    isHovered ? PixelStyle.ink(colorTheme) : .clear
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
    }
}
