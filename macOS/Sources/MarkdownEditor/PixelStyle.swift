import MarkdownEditorUI
import SwiftUI

/// The look: 8-bit, minimal, and quiet enough to write in.
///
/// Three rules, and they are rules rather than decoration because the moment
/// one is broken the whole thing reads as a normal app with an odd corner:
///
///  * **Square corners.** A rounded rectangle is the one shape a pixel grid
///    cannot draw. Everything is a rectangle.
///  * **Hard shadows.** A blurred shadow is a gradient, and a gradient is the
///    other thing a pixel grid cannot draw. Shadows are a solid block offset
///    down and right, the way a sprite is dropped on a background.
///  * **Hairline borders.** One point, full strength. No inner glow, no
///    gradient stroke, nothing that softens the edge.
///
/// What is deliberately *not* 8-bit: the document's own text. A pixel typeface
/// in the body would make this a toy rather than an editor, and the reason
/// anybody opens it is to read and write prose. The style lives in the chrome
/// and the frame around the page.
enum PixelStyle {
    /// How far a dropped block sits from the thing that cast it.
    static let shadowOffset: CGFloat = 3
    /// The same, for something raised further off the surface.
    static let liftedShadowOffset: CGFloat = 5
    static let border: CGFloat = 1

    static func shadow(_ theme: EditorColorTheme) -> Color {
        // Tied to the text colour rather than to black, so a dark theme casts
        // a light shadow and the effect survives the palette changing.
        Color(platformColor: theme.primaryTextColor).opacity(
            theme.mode == .dark ? 0.55 : 0.18
        )
    }

    /// The surface the page lies on.
    ///
    /// Deliberately deeper than the palette's own canvas, which is within a
    /// few percent of the page colour — a sheet of paper on a background the
    /// same colour as the paper is not a sheet of paper, it is a margin. The
    /// tone is mixed from the palette rather than picked, so it still tracks
    /// the theme instead of being one grey for all sixteen.
    static func canvas(_ theme: EditorColorTheme) -> Color {
        let base = theme.canvasBackgroundColor
        let mixed = base.blended(
            with: theme.primaryTextColor,
            fraction: theme.mode == .dark ? 0.10 : 0.13
        ) ?? base
        return Color(platformColor: mixed)
    }

    static func line(_ theme: EditorColorTheme) -> Color {
        Color(platformColor: theme.primaryTextColor).opacity(
            theme.mode == .dark ? 0.42 : 0.22
        )
    }
}

/// A faint grid, drawn behind the page.
///
/// Crisp on purpose: the lines are placed on whole points and drawn one point
/// wide, so they stay hairlines rather than blurring into grey bands. A grid
/// that has gone soft is just texture.
struct PixelGrid: View {
    let theme: EditorColorTheme
    var spacing: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let colour = Color(platformColor: theme.primaryTextColor)
                .opacity(theme.mode == .dark ? 0.10 : 0.055)
            var path = Path()
            var x = spacing
            while x < size.width {
                path.move(to: CGPoint(x: x.rounded(), y: 0))
                path.addLine(to: CGPoint(x: x.rounded(), y: size.height))
                x += spacing
            }
            var y = spacing
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y.rounded()))
                path.addLine(to: CGPoint(x: size.width, y: y.rounded()))
                y += spacing
            }
            context.stroke(path, with: .color(colour), lineWidth: 1)
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

/// How far a note is turned, and which way.
///
/// Derived from the finding's identifier rather than drawn at random, and that
/// is the whole point: a random angle is recomputed on every redraw, so the
/// notes would twitch each time the score changed or a card was answered.
/// Deterministic from the id, they sit still.
///
/// Not `hashValue` either — Swift seeds that per process, so the angles would
/// be different every launch. Same wall as naming the history file.
enum PixelJitter {
    static func angle(for id: UUID, limit: Double = 2.6) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(id.uuidString.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        // A stable value in -1...1, then scaled to the range worth turning.
        let unit = Double(hash % 2_001) / 1_000 - 1
        return unit * limit
    }

    /// A small sideways nudge, so the notes are not left-aligned to the point.
    static func offset(for id: UUID, limit: Double = 3) -> CGFloat {
        var hash: UInt64 = 0x1000_0000_01b3
        for byte in Array(id.uuidString.utf8).reversed() {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return CGFloat(Double(hash % 2_001) / 1_000 - 1) * limit
    }
}

/// A flat block with a hard edge and a hard shadow.
struct PixelPanel: ViewModifier {
    let theme: EditorColorTheme
    var fill: Color
    var offset: CGFloat = PixelStyle.shadowOffset
    var stroke: Color?

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // The shadow first, as its own rectangle rather than a
                    // `.shadow` — SwiftUI's is always blurred, and a blur is a
                    // gradient.
                    Rectangle()
                        .fill(PixelStyle.shadow(theme))
                        .offset(x: offset, y: offset)
                    Rectangle().fill(fill)
                    Rectangle()
                        .strokeBorder(
                            stroke ?? PixelStyle.line(theme),
                            lineWidth: PixelStyle.border
                        )
                }
            )
    }
}


extension View {
    func pixelPanel(
        _ theme: EditorColorTheme,
        fill: Color,
        offset: CGFloat = PixelStyle.shadowOffset,
        stroke: Color? = nil
    ) -> some View {
        modifier(PixelPanel(theme: theme, fill: fill, offset: offset, stroke: stroke))
    }

}
