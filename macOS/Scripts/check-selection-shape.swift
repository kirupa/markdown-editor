// Is a selection drawn as rounded bars fitted to its words, fading out where
// it carries on to the next line and in where it arrives — and is AppKit's
// square, full-width band gone?
//
// `SelectionHighlightSegment`'s tests prove the shape on paper. This proves
// the drawing: a real `RichMarkdownTextView` with its real layout manager,
// showing a document styled by the real styler, drawn into a bitmap and read
// back a pixel at a time.
//
// The window is never shown and never made key; it only says it is.
//
// Built by Scripts/run-selection-shape-checks.sh against the real app sources.
// Set SELECTION_SNAPSHOTS to a folder to keep what was drawn.

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

/// A window that can claim to be the key window without being brought in
/// front of the one the person at the Mac is using.
final class PretendKeyWindow: NSWindow {
    var claimsKey = true
    override var isKeyWindow: Bool { claimsKey }
    override var canBecomeKey: Bool { true }
}

private let source = """
    # Choosing where to go

    The quick brown fox jumps over the lazy dog and keeps on running along \
    the bank of the river until it reaches the bridge.

    A short line.

    Then `a little code` and a final line of prose.
    """

/// One editor, laid out and ready to draw.
@MainActor
struct Editor {
    let view: RichMarkdownTextView
    let window: PretendKeyWindow
    let theme: EditorColorTheme

    init(theme: EditorColorTheme, width: CGFloat = 560) {
        self.theme = theme
        let model = MarkdownRenderer.render(source)
        let styled = RichMarkdownStyler.attributedString(
            for: model, documentURL: nil, colorTheme: theme
        )
        let frame = NSRect(x: 0, y: 0, width: width, height: 420)
        let view = RichMarkdownTextView(frame: frame)
        view.adoptSelectionLayoutManager()
        view.textContainerInset = NSSize(width: 24, height: 20)
        view.textContainer?.containerSize = NSSize(
            width: frame.width - 48, height: .greatestFiniteMagnitude
        )
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(styled)
        theme.apply(to: view, in: NSScrollView(frame: frame))
        let window = PretendKeyWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeFirstResponder(view)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        self.view = view
        self.window = window
    }

    func range(of text: String) -> NSRange {
        (view.string as NSString).range(of: text)
    }

    func select(from start: String, through end: String) {
        let first = range(of: start)
        let last = range(of: end)
        view.setSelectedRange(NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        ))
    }

    /// Drawn at 2x into sRGB, the space the theme's colours are written in.
    /// The display's own profile would shift a dark page by more than the
    /// faint tint a selection adds to it.
    func draw() -> Picture {
        let size = view.bounds.size
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!.retagging(with: .sRGB)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return Picture(rep: rep, size: size)
    }

    /// Where a piece of text is drawn, in the view.
    func rect(of text: String) -> NSRect {
        let layoutManager = view.layoutManager!
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: range(of: text), actualCharacterRange: nil
        )
        return layoutManager.boundingRect(
            forGlyphRange: glyphs, in: view.textContainer!
        ).offsetBy(
            dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y
        )
    }
}

/// What was drawn, read in the view's own points.
struct Picture {
    let rep: NSBitmapImageRep
    let size: NSSize

    func color(at point: NSPoint) -> NSColor {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let x = min(max(0, Int(point.x * scale)), rep.pixelsWide - 1)
        let y = min(max(0, Int(point.y * scale)), rep.pixelsHigh - 1)
        // The bytes are sRGB, but `colorAt` labels them with a generic RGB
        // space, and converting from that would shift every mid-tone. So the
        // components are taken as they are.
        let raw = rep.colorAt(x: x, y: y)!
        return NSColor(
            srgbRed: raw.redComponent,
            green: raw.greenComponent,
            blue: raw.blueComponent,
            alpha: raw.alphaComponent
        )
    }

    func save(_ name: String) {
        guard let folder = ProcessInfo.processInfo
            .environment["SELECTION_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder)
            .appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// How much of `tint` a pixel shows over `page`: 0 is the bare page, 1 the
/// tint at full strength.
func strength(of pixel: NSColor, tint: NSColor, page: NSColor) -> CGFloat {
    let pixel = pixel.usingColorSpace(.sRGB)!
    let page = page.usingColorSpace(.sRGB)!
    let tint = tint.usingColorSpace(.sRGB)!
    let alpha = tint.alphaComponent
    let full = [
        tint.redComponent * alpha + page.redComponent * (1 - alpha),
        tint.greenComponent * alpha + page.greenComponent * (1 - alpha),
        tint.blueComponent * alpha + page.blueComponent * (1 - alpha),
    ]
    let bare = [page.redComponent, page.greenComponent, page.blueComponent]
    let seen = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
    var along: CGFloat = 0
    var length: CGFloat = 0
    for channel in 0..<3 {
        let span = full[channel] - bare[channel]
        along += (seen[channel] - bare[channel]) * span
        length += span * span
    }
    return length > 0 ? along / length : 0
}

@MainActor
func checkShape(theme: EditorColorTheme, name: String) {
    print("\(theme.title): the shape of a selection")
    let editor = Editor(theme: theme)
    let view = editor.view
    let page = theme.editorBackgroundColor
    let tint = theme.textSelectionBackgroundColor

    // From the middle of the long paragraph, through the short one, to the
    // middle of the last: lines that start it, run on, and end it, and one
    // short line whose break is selected.
    editor.select(from: "brown", through: "Then")
    let segments = view.selectionHighlightSegments(in: view.bounds)
    check(
        "one bar per line the selection crosses",
        segments.count >= 4,
        "\(segments.count) bars"
    )
    guard let first = segments.first, let last = segments.last,
          segments.count >= 4
    else { return }
    check(
        "the first line starts hard and fades out",
        first.fadeIn == 0 && first.fadeOut > 0
    )
    check(
        "the last line fades in and stops hard",
        last.fadeIn > 0 && last.fadeOut == 0
    )
    check(
        "the lines between fade at both ends",
        segments.dropFirst().dropLast().allSatisfy {
            $0.fadeIn > 0 && $0.fadeOut > 0
        }
    )

    let picture = editor.draw()
    picture.save("selection-\(name)")
    func seen(_ point: NSPoint) -> CGFloat {
        strength(of: picture.color(at: point), tint: tint, page: page)
    }

    // Between two selected words: the tint, at full strength.
    let gap = editor.rect(of: " fox ")
    let between = NSPoint(x: gap.minX + 1.5, y: first.rect.midY)
    check(
        "a selected space is fully tinted",
        abs(seen(between) - 1) < 0.2,
        "strength \(seen(between))"
    )

    // Just past the rounding of the bar's first corner the page shows, and
    // just inside the same edge at mid-height the bar does.
    let corner = NSPoint(x: first.rect.minX + 0.6, y: first.rect.minY + 0.6)
    let edge = NSPoint(x: first.rect.minX + 0.9, y: first.rect.midY)
    check(
        "the bar's corners are rounded",
        seen(corner) < 0.4 && seen(edge) > 0.7,
        "corner \(seen(corner)), edge \(seen(edge))"
    )

    // The short line: its break is selected, so AppKit's band ran to the
    // edge of the column. This one fades out after the last word instead.
    let shortWords = editor.rect(of: "A short line.")
    guard let short = segments.first(where: {
        abs($0.rect.midY - shortWords.midY) < 4
    }) else {
        check("the short line has a bar", false)
        return
    }
    let fadeStart = shortWords.maxX
    let fade = short.rect.maxX - fadeStart
    let y = short.rect.midY
    let along = [0.2, 0.5, 0.8].map {
        seen(NSPoint(x: fadeStart + fade * $0, y: y))
    }
    check(
        "the end of a line fades out, getting fainter",
        along[0] > along[1] && along[1] > along[2] && along[0] > 0.5
            && along[2] < 0.35,
        "\(along)"
    )
    let column = view.textContainerOrigin.x
        + view.textContainer!.size.width
    let margin = NSPoint(x: min(column - 8, short.rect.maxX + 30), y: y)
    check(
        "nothing is drawn past the fade — AppKit's band is gone",
        short.rect.maxX + 30 < column - 8 ? seen(margin) < 0.05 : true,
        "strength \(seen(margin)) at \(margin.x)"
    )

    // The line after the short one fades in ahead of its first word.
    let arriving = segments[segments.count - 1]
    let fadeIn = NSPoint(
        x: arriving.rect.minX + arriving.fadeIn * 0.5, y: arriving.rect.midY
    )
    check(
        "the start of a line the selection arrives on fades in",
        seen(fadeIn) > 0.15 && seen(fadeIn) < 0.85,
        "strength \(seen(fadeIn))"
    )

    // Two lines of one paragraph are separate bars, with a sliver of page
    // between them, rather than one slab.
    let second = segments[1]
    let between2 = NSPoint(
        x: (max(first.rect.minX, second.rect.minX) + 60),
        y: (first.rect.maxY + second.rect.minY) / 2
    )
    check(
        "wrapped lines are separate bars",
        second.rect.minY > first.rect.maxY && seen(between2) < 0.35,
        "gap \(second.rect.minY - first.rect.maxY), strength \(seen(between2))"
    )

    // A window in the background: the theme's resting tint, not the system's
    // grey and not the active tint.
    editor.window.claimsKey = false
    view.redrawSelectionHighlight()
    let resting = editor.draw()
    resting.save("selection-\(name)-inactive")
    let restingStrength = strength(
        of: resting.color(at: between),
        tint: theme.inactiveTextSelectionBackgroundColor,
        page: page
    )
    check(
        "in the background the selection keeps a quieter tint of its own",
        abs(restingStrength - 1) < 0.25,
        "strength \(restingStrength) of the resting tint"
    )
    editor.window.claimsKey = true

    // And once it collapses to a caret, nothing.
    view.setSelectedRange(NSRange(location: editor.range(of: "fox").location, length: 0))
    let cleared = editor.draw()
    let after = strength(of: cleared.color(at: between), tint: tint, page: page)
    check(
        "a caret draws no bar",
        view.selectionHighlightSegments(in: view.bounds).isEmpty && after < 0.1,
        "strength \(after)"
    )
}

@MainActor
func checkEmptyLine() {
    print("An empty line inside a selection")
    let editor = Editor(theme: EditorColorTheme(color: .blue, mode: .light))
    // From the end of the long paragraph's last word to the start of the
    // short one: the selection is nothing but line breaks and a blank line.
    let end = editor.range(of: "bridge.")
    let next = editor.range(of: "A short")
    editor.view.setSelectedRange(NSRange(
        location: NSMaxRange(end), length: next.location - NSMaxRange(end)
    ))
    let segments = editor.view.selectionHighlightSegments(
        in: editor.view.bounds
    )
    check(
        "a selection of only line breaks still shows",
        !segments.isEmpty && segments.allSatisfy { $0.rect.width > 0 },
        "\(segments.count) bars"
    )
}

@MainActor
func checkTextScale() {
    print("Customize Theme ▸ Size")
    var heights: [CGFloat] = []
    for scale: CGFloat in [0.75, 1, 1.5] {
        let theme = EditorColorTheme(
            color: .green, mode: .light, textScale: scale
        )
        let editor = Editor(theme: theme)
        editor.select(from: "quick", through: "short")
        let picture = editor.draw()
        picture.save("size-\(Int(scale * 100))")
        heights.append(editor.rect(of: "The quick").height)
    }
    check(
        "the text is drawn larger as the size goes up",
        heights[0] < heights[1] && heights[1] < heights[2],
        "\(heights)"
    )
    check(
        "150% is half as large again as 100%",
        abs(heights[2] / heights[1] - 1.5) < 0.12,
        "\(heights[2] / heights[1])"
    )
}

@main
struct CheckSelectionShape {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        checkShape(
            theme: EditorColorTheme(color: .blue, mode: .light),
            name: "blue-light"
        )
        checkShape(
            theme: EditorColorTheme(color: .blue, mode: .dark),
            name: "blue-dark"
        )
        checkEmptyLine()
        checkTextScale()
        print("\(checks - failures) of \(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
