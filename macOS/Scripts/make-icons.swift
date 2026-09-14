// Generates the app and document icons.
//
// Run with `make icons`, which writes `Packaging/AppIcon.icns` and
// `Packaging/MarkdownDocument.icns`. The results are committed, so a normal
// build does not need to run this.
//
// Everything is drawn with Core Graphics and packed by `iconutil`, both of
// which ship with macOS, so no asset pipeline or design tool is required. The
// one piece of artwork, the kirupa mark, is vendored beside this script's
// output as an SVG rather than read from wherever it happens to live on one
// Mac, so that regenerating the icons does not depend on a path only one
// person has.

import AppKit
import Foundation

let brand = NSColor(srgbRed: 0x07 / 255, green: 0x98 / 255, blue: 0xFF / 255, alpha: 1)

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// The kirupa mark, as vectors, so every size in the iconset is rendered at
/// that size rather than resampled from one bitmap. The 16pt entries in a
/// `.icns` are small enough that resampling shows.
let logo: NSImage = {
    let file = destination.appendingPathComponent("kirupa-logo.svg")
    guard let image = NSImage(contentsOf: file) else {
        FileHandle.standardError.write(
            Data("cannot read \(file.path)\n".utf8)
        )
        exit(1)
    }
    return image
}()

func makeBitmap(size: Int, draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    representation.size = NSSize(width: size, height: size)

    let context = NSGraphicsContext(bitmapImageRep: representation)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.setAllowsAntialiasing(true)
    context.cgContext.interpolationQuality = .high
    draw(context.cgContext, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()

    return representation
}

/// Where the mark's visible ink sits inside its own square, as a fraction of
/// that square, measured rather than guessed.
///
/// The artwork is not centered in its canvas: the leaves push it up and to the
/// left, and its white backing circle — invisible against a white plate, but
/// perfectly real to anything counting pixels — extends further still.
/// Centering the canvas would therefore leave the fruit sitting visibly low
/// and right of the middle of the icon. Measuring against white asks the same
/// question the eye asks, which is where the ink starts and stops.
let inkBounds: NSRect = {
    let side = 512
    let rendered = makeBitmap(size: side) { _, size in
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        logo.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    }

    var minX = side, maxX = -1, minRow = side, maxRow = -1
    for row in 0..<side {
        for column in 0..<side {
            guard let pixel = rendered.colorAt(x: column, y: row) else { continue }
            let isPaper =
                pixel.redComponent > 0.99 && pixel.greenComponent > 0.99
                && pixel.blueComponent > 0.99
            if isPaper { continue }
            minX = min(minX, column)
            maxX = max(maxX, column)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
        }
    }
    guard maxX >= minX, maxRow >= minRow else {
        FileHandle.standardError.write(Data("the mark rendered blank\n".utf8))
        exit(1)
    }

    // `colorAt` counts rows from the top; NSRect counts up from the bottom.
    let edge = CGFloat(side)
    return NSRect(
        x: CGFloat(minX) / edge,
        y: CGFloat(side - 1 - maxRow) / edge,
        width: CGFloat(maxX - minX + 1) / edge,
        height: CGFloat(maxRow - minRow + 1) / edge
    )
}()

/// Draws the mark so that its *ink* — not its canvas — is centered in `rect`
/// and fills it, keeping the artwork's aspect ratio.
func drawLogo(in rect: NSRect) {
    let edge = min(rect.width / inkBounds.width, rect.height / inkBounds.height)
    let ink = NSSize(width: inkBounds.width * edge, height: inkBounds.height * edge)
    logo.draw(
        in: NSRect(
            x: rect.midX - ink.width / 2 - inkBounds.minX * edge,
            y: rect.midY - ink.height / 2 - inkBounds.minY * edge,
            width: edge,
            height: edge
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
}

/// The rounded-rectangle app icon: the kirupa mark on a white squircle, inset
/// to match the macOS icon grid.
///
/// White rather than a colored plate because the mark carries its own color and
/// was drawn to sit on paper — the orange against a blue gradient reads as two
/// brands stacked. It also means the Dock entry is a white tile, which is what
/// separates it from the rest of the row at a glance.
func drawAppIcon(_ context: CGContext, _ size: CGFloat) {
    let inset = size * 0.086
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    NSColor.white.setFill()
    path.fill()

    // A hairline, because a white tile on the light Dock has no edge of its own
    // and dissolves into the background it is sitting on.
    NSColor(white: 0.86, alpha: 1).setStroke()
    path.lineWidth = max(1, size * 0.004)
    path.stroke()

    let side = plate.width * 0.72
    drawLogo(
        in: NSRect(
            x: plate.midX - side / 2,
            y: plate.midY - side / 2,
            width: side,
            height: side
        )
    )
}

/// The document icon: a white page with a folded corner, a few text rules, and
/// a brand-colored MD badge.
func drawDocumentIcon(_ context: CGContext, _ size: CGFloat) {
    let width = size * 0.68
    let height = size * 0.84
    let page = NSRect(
        x: (size - width) / 2,
        y: (size - height) / 2,
        width: width,
        height: height
    )
    let fold = width * 0.26
    let corner = width * 0.035

    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: page.minX + corner, y: page.minY))
    outline.line(to: NSPoint(x: page.maxX - corner, y: page.minY))
    outline.curve(
        to: NSPoint(x: page.maxX, y: page.minY + corner),
        controlPoint1: NSPoint(x: page.maxX, y: page.minY),
        controlPoint2: NSPoint(x: page.maxX, y: page.minY)
    )
    outline.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    outline.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    outline.line(to: NSPoint(x: page.minX + corner, y: page.maxY))
    outline.curve(
        to: NSPoint(x: page.minX, y: page.maxY - corner),
        controlPoint1: NSPoint(x: page.minX, y: page.maxY),
        controlPoint2: NSPoint(x: page.minX, y: page.maxY)
    )
    outline.line(to: NSPoint(x: page.minX, y: page.minY + corner))
    outline.curve(
        to: NSPoint(x: page.minX + corner, y: page.minY),
        controlPoint1: NSPoint(x: page.minX, y: page.minY),
        controlPoint2: NSPoint(x: page.minX, y: page.minY)
    )
    outline.close()

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -size * 0.008),
        blur: size * 0.02,
        color: NSColor(white: 0, alpha: 0.22).cgColor
    )
    NSColor.white.setFill()
    outline.fill()
    context.restoreGState()

    NSColor(white: 0.80, alpha: 1).setStroke()
    outline.lineWidth = max(1, size * 0.004)
    outline.stroke()

    // The turned-down corner.
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    flap.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    flap.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    flap.close()
    NSColor(white: 0.90, alpha: 1).setFill()
    flap.fill()
    NSColor(white: 0.80, alpha: 1).setStroke()
    flap.lineWidth = max(1, size * 0.004)
    flap.stroke()

    // Text rules, shortest last so the block reads as a paragraph.
    let ruleHeight = height * 0.030
    let ruleGap = height * 0.062
    let ruleLeft = page.minX + width * 0.14
    let ruleWidths: [CGFloat] = [0.72, 0.60, 0.68, 0.44]
    NSColor(white: 0.82, alpha: 1).setFill()
    for (index, fraction) in ruleWidths.enumerated() {
        let rule = NSRect(
            x: ruleLeft,
            y: page.maxY - fold - height * 0.10 - CGFloat(index) * ruleGap,
            width: width * fraction,
            height: ruleHeight
        )
        NSBezierPath(
            roundedRect: rule,
            xRadius: ruleHeight / 2,
            yRadius: ruleHeight / 2
        ).fill()
    }

    // Brand badge.
    let badgeHeight = height * 0.24
    let badge = NSRect(
        x: page.minX + width * 0.14,
        y: page.minY + height * 0.10,
        width: width * 0.50,
        height: badgeHeight
    )
    brand.setFill()
    NSBezierPath(
        roundedRect: badge,
        xRadius: badgeHeight * 0.24,
        yRadius: badgeHeight * 0.24
    ).fill()

    let label = "MD"
    let font = NSFont.systemFont(ofSize: badgeHeight * 0.60, weight: .bold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let measured = label.size(withAttributes: attributes)
    label.draw(
        at: NSPoint(
            x: badge.midX - measured.width / 2,
            y: badge.midY - measured.height / 2
        ),
        withAttributes: attributes
    )
}

func writeIconSet(
    named name: String,
    into directory: URL,
    draw: @escaping (CGContext, CGFloat) -> Void
) throws {
    let iconset = directory.appendingPathComponent("\(name).iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // (point size, scale) pairs required by iconutil.
    let variants: [(Int, Int)] = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2),
    ]
    for (points, scale) in variants {
        let pixels = points * scale
        let representation = makeBitmap(size: pixels, draw: draw)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "make-icons", code: 1)
        }
        let suffix = scale == 1 ? "" : "@\(scale)x"
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try data.write(to: file)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = [
        "--convert", "icns",
        "--output", directory.appendingPathComponent("\(name).icns").path,
        iconset.path,
    ]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "iconutil", code: Int(process.terminationStatus))
    }

    try FileManager.default.removeItem(at: iconset)
    print("Wrote \(directory.appendingPathComponent("\(name).icns").path)")
}

try writeIconSet(named: "AppIcon", into: destination, draw: drawAppIcon)
try writeIconSet(named: "MarkdownDocument", into: destination, draw: drawDocumentIcon)

/// The iOS app icon.
///
/// Full-bleed and square: iOS applies its own rounded-rectangle mask and
/// shadow, so an icon that draws its own rounded plate the way the macOS one
/// does ends up with a visible double edge inside the system's corners. That
/// also rules out the macOS icon's hairline, and there is no need for it —
/// the home screen puts a shadow under every icon, so a white tile has an edge
/// whatever it is sitting on.
func drawIOSAppIcon(_ context: CGContext, _ size: CGFloat) {
    let plate = NSRect(x: 0, y: 0, width: size, height: size)

    NSColor.white.setFill()
    plate.fill()

    // Smaller than the macOS mark relative to its plate, since iOS's mask
    // takes a larger bite out of the corners than the squircle above does.
    let side = size * 0.62
    drawLogo(
        in: NSRect(
            x: plate.midX - side / 2,
            y: plate.midY - side / 2,
            width: side,
            height: side
        )
    )
}

/// Writes the single 1024×1024 PNG an iOS asset catalog expects.
func writeIOSAppIcon(into appIconSet: URL) throws {
    let representation = makeBitmap(size: 1024, draw: drawIOSAppIcon)
    guard let data = representation.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "png", code: 1)
    }
    try FileManager.default.createDirectory(
        at: appIconSet, withIntermediateDirectories: true
    )
    let file = appIconSet.appendingPathComponent("AppIcon.png")
    try data.write(to: file)
    print("Wrote \(file.path)")
}

if CommandLine.arguments.count > 2 {
    try writeIOSAppIcon(
        into: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    )
}
