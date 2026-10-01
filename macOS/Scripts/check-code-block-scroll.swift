// Does a code block keep its shading when only part of it is redrawn?
//
// Scrolling doesn't redraw the pane. AppKit moves what is already drawn and
// asks the text view only for the strip that has just come into view — often
// a point or two tall. The code block's rounded box has to come out the same
// whatever slice of it is asked for, or the lines a scroll brings in stay
// unshaded until something redraws them whole, like selecting them.
//
// This draws a real `RichMarkdownTextView`, with the rendered pane's real
// insets, showing a document styled by the real styler: once whole, then a
// strip at a time across a tall code block. Every strip has to match the same
// pixels of the whole.
//
// The strips go straight to `drawBackground(in:)`, where the box is painted,
// because that is what a scroll does: in a real scroll view, a 4pt nudge
// hands it a rect 4pt tall. Snapshotting the view instead hands it the whole
// view every time, and the whole view always drew the box right.
//
// The window is never shown and no mouse is moved, so it runs behind a locked
// screen.
//
// Built by Scripts/run-code-block-scroll-checks.sh against the real app
// sources. Set CODE_BLOCK_SNAPSHOTS to a folder to keep what was drawn.

import AppKit
import MarkdownEditorCore
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

/// Prose, a code block taller than a few scroll steps, and more prose, so
/// the block has neighbours above and below.
private let source: String = {
    var lines = [
        "# Scrolling past code",
        "",
        "A paragraph before the code, long enough to wrap onto a second "
            + "line in a pane this narrow.",
        "",
        "```swift",
    ]
    for number in 1...14 {
        lines.append("let line\(number) = \(number)")
    }
    lines += ["```", "", "A paragraph after the code."]
    for _ in 0..<4 {
        lines += ["", "More prose, so the document carries on below it."]
    }
    return lines.joined(separator: "\n")
}()

/// One editor, laid out whole and ready to draw.
@MainActor
struct Editor {
    let view: RichMarkdownTextView
    let window: NSWindow

    init(theme: EditorColorTheme, width: CGFloat = 560) {
        let model = MarkdownRenderer.render(source)
        let styled = RichMarkdownStyler.attributedString(
            for: model, documentURL: nil, colorTheme: theme
        )
        let frame = NSRect(x: 0, y: 0, width: width, height: 400)
        let view = RichMarkdownTextView(frame: frame)
        view.adoptSelectionLayoutManager()
        // The rendered pane's own insets. The code block's search once
        // measured the rect it was given as if they were not there.
        view.textContainerInset = NSSize(
            width: Layout.textContainerInset, height: Layout.textTopInset
        )
        view.textContainer?.containerSize = NSSize(
            width: width - 2 * Layout.textContainerInset,
            height: .greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(styled)
        theme.apply(to: view, in: NSScrollView(frame: frame))
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        self.view = view
        self.window = window
    }

    /// Where a piece of text is laid out, in the view.
    func rect(of text: String) -> NSRect {
        let layoutManager = view.layoutManager!
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: (view.string as NSString).range(of: text),
            actualCharacterRange: nil
        )
        return layoutManager.boundingRect(
            forGlyphRange: glyphs, in: view.textContainer!
        ).offsetBy(
            dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y
        )
    }

    /// The view's background asked for `rect` and nothing else, as a scroll
    /// asks for it, at 2x into sRGB.
    ///
    /// `cacheDisplay(in:to:)` won't do: however small the rect, it hands the
    /// view its whole bounds to draw and clips afterwards, which is exactly
    /// the draw that has always come out right.
    func draw(_ rect: NSRect) -> Picture {
        let scale: CGFloat = 2
        let pixelsHigh = Int((rect.height * scale).rounded())
        let context = CGContext(
            data: nil,
            width: Int((rect.width * scale).rounded()),
            height: pixelsHigh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Flipped like the view, with the rect's top-left at the first pixel.
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        context.clip(to: rect)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(
            cgContext: context, flipped: true
        )
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.drawBackground(in: rect)
        }
        NSGraphicsContext.current = previous
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        rep.size = rect.size
        return Picture(rep: rep, origin: rect.origin)
    }
}

/// What was drawn, with where it was drawn from.
struct Picture {
    let rep: NSBitmapImageRep
    let origin: NSPoint

    private var scale: CGFloat { CGFloat(rep.pixelsWide) / rep.size.width }

    /// The colour at a point of the view.
    func color(at point: NSPoint) -> NSColor {
        let x = Int(((point.x - origin.x) * scale).rounded(.down))
        let y = Int(((point.y - origin.y) * scale).rounded(.down))
        let raw = rep.colorAt(
            x: min(max(0, x), rep.pixelsWide - 1),
            y: min(max(0, y), rep.pixelsHigh - 1)
        )!
        return NSColor(
            srgbRed: raw.redComponent,
            green: raw.greenComponent,
            blue: raw.blueComponent,
            alpha: raw.alphaComponent
        )
    }

    /// The first pixel of this picture that isn't what `whole` has at the
    /// same place in the view, as a point in the view.
    func firstDifference(from whole: Picture) -> NSPoint? {
        let offsetX = Int(((origin.x - whole.origin.x) * scale).rounded())
        let offsetY = Int(((origin.y - whole.origin.y) * scale).rounded())
        let mine = rep.bitmapData!
        let theirs = whole.rep.bitmapData!
        for row in 0..<rep.pixelsHigh {
            for column in 0..<rep.pixelsWide {
                let here = row * rep.bytesPerRow + column * 4
                let there = (row + offsetY) * whole.rep.bytesPerRow
                    + (column + offsetX) * 4
                for channel in 0..<4
                where abs(Int(mine[here + channel])
                    - Int(theirs[there + channel])) > 2 {
                    return NSPoint(
                        x: origin.x + CGFloat(column) / scale,
                        y: origin.y + CGFloat(row) / scale
                    )
                }
            }
        }
        return nil
    }

    func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo
            .environment["CODE_BLOCK_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder)
            .appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// How far apart two colours are, in sRGB, 0 to 1 per channel.
func distance(_ first: NSColor, _ second: NSColor) -> CGFloat {
    let first = first.usingColorSpace(.sRGB)!
    let second = second.usingColorSpace(.sRGB)!
    return max(
        abs(first.redComponent - second.redComponent),
        abs(first.greenComponent - second.greenComponent),
        abs(first.blueComponent - second.blueComponent)
    )
}

@MainActor
func checkScrolling(theme: EditorColorTheme, name: String) {
    print("\(theme.title): a code block uncovered a strip at a time")
    let editor = Editor(theme: theme)
    let view = editor.view
    let whole = editor.draw(view.bounds)
    whole.save("whole-\(name)")

    let first = editor.rect(of: "let line1 =")
    let last = editor.rect(of: "let line14 =")
    // Clear of the code, which is short, but inside the box, which runs the
    // width of the column.
    let shadeX = view.bounds.maxX - Layout.textContainerInset - 16
    let block = theme.codeBlockBackgroundColor
    let page = theme.editorBackgroundColor
    let shaded = { (color: NSColor) in
        distance(color, block) < distance(color, page)
    }
    check(
        "drawn whole, the block is shaded from its first line to its last",
        shaded(whole.color(at: NSPoint(x: shadeX, y: first.midY)))
            && shaded(whole.color(at: NSPoint(x: shadeX, y: last.midY))),
        "the column at x \(shadeX) isn't the code block's colour"
    )

    // Strips as tall as a trackpad's smallest nudge and as a mouse wheel's
    // click, from above the block to below it, a half point apart: every
    // place a scroll can stop.
    let top = first.minY - 24
    let bottom = last.maxY + 24
    var strips = 0
    var differing: [String] = []
    var lastLines: [String] = []
    for height in [0.5, 2, 8, 30] as [CGFloat] {
        var y = top
        while y < bottom {
            let strip = NSRect(
                x: 0, y: y, width: view.bounds.width, height: height
            )
            let picture = editor.draw(strip)
            strips += 1
            if let point = picture.firstDifference(from: whole) {
                if differing.count < 3 {
                    differing.append(
                        "h \(height) at y \(y): first at "
                            + "(\(point.x), \(point.y))"
                    )
                } else if differing.count == 3 {
                    differing.append("…")
                }
            }
            // What was actually seen: the block's last line left bare.
            let probe = NSPoint(x: shadeX, y: y + height / 2)
            if probe.y >= last.minY, probe.y < last.maxY,
               !shaded(picture.color(at: probe)),
               lastLines.count < 3 {
                lastLines.append("h \(height) at y \(y)")
                picture.save("bare-\(name)-\(Int(height * 2))-\(Int(y * 2))")
            }
            y += 0.5
        }
    }
    check(
        "the block's last line is shaded however little of it is redrawn",
        lastLines.isEmpty,
        "bare in " + lastLines.joined(separator: "; ")
    )
    check(
        "every strip of \(strips) draws what the whole draw has there",
        differing.isEmpty,
        differing.joined(separator: "; ")
    )

    // Narrower than the pane, clear of the code: a strip needn't have a
    // character in it to be inside the box.
    var tiles = 0
    var differingTiles: [String] = []
    for height in [2, 12] as [CGFloat] {
        var y = top
        while y < bottom {
            let tile = NSRect(
                x: shadeX - 24, y: y, width: 48, height: height
            )
            let picture = editor.draw(tile)
            tiles += 1
            if picture.firstDifference(from: whole) != nil,
               differingTiles.count < 3 {
                differingTiles.append("h \(height) at y \(y)")
            }
            y += 1
        }
    }
    check(
        "every tile of \(tiles) clear of the code draws what the whole has",
        differingTiles.isEmpty,
        differingTiles.joined(separator: "; ")
    )
}

@main
struct CheckCodeBlockScroll {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        checkScrolling(
            theme: EditorColorTheme(color: .blue, mode: .light),
            name: "blue-light"
        )
        checkScrolling(
            theme: EditorColorTheme(color: .blue, mode: .dark),
            name: "blue-dark"
        )
        print("\(checks - failures) of \(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
