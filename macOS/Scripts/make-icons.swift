// Generates the app and document icons.
//
// Run with `make icons`, which writes `Packaging/AppIcon.icns` and
// `Packaging/MarkdownDocument.icns`. The results are committed, so a normal
// build does not need to run this.
//
// Everything is drawn with Core Graphics and packed by `iconutil`, both of
// which ship with macOS, so no asset pipeline or design tool is required.

import AppKit
import Foundation

let brand = NSColor(srgbRed: 0x07 / 255, green: 0x98 / 255, blue: 0xFF / 255, alpha: 1)
let brandDark = NSColor(srgbRed: 0x00 / 255, green: 0x66 / 255, blue: 0xAF / 255, alpha: 1)

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

/// Draws `symbol` centered in `rect`, scaled to fit while keeping its aspect.
func drawSymbol(
    _ symbol: String,
    in rect: NSRect,
    weight: NSFont.Weight,
    color: NSColor
) {
    let configuration = NSImage.SymbolConfiguration(
        pointSize: rect.height,
        weight: weight
    )
    guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    else {
        FileHandle.standardError.write(Data("missing symbol \(symbol)\n".utf8))
        exit(1)
    }

    // System symbols are template images. Tinting has to happen in a scratch
    // image, where `sourceAtop` can only touch the glyph's own alpha rather
    // than everything already drawn underneath.
    let natural = image.size
    let tinted = NSImage(size: natural)
    tinted.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: natural))
    color.set()
    NSRect(origin: .zero, size: natural).fill(using: .sourceAtop)
    tinted.unlockFocus()

    let scale = min(rect.width / natural.width, rect.height / natural.height)
    let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
    tinted.draw(
        in: NSRect(
            origin: NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2),
            size: drawn
        ),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: false,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
}

/// The rounded-rectangle app icon: a blue gradient squircle with a white
/// document glyph, inset to match the macOS icon grid.
func drawAppIcon(_ context: CGContext, _ size: CGFloat) {
    let inset = size * 0.086
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    context.saveGState()
    path.addClip()
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0x4F / 255, green: 0xB8 / 255, blue: 0xFF / 255, alpha: 1),
            brand,
            brandDark,
        ],
        atLocations: [0, 0.55, 1],
        colorSpace: .sRGB
    )!
    gradient.draw(in: plate, angle: -90)
    context.restoreGState()

    let glyph = NSRect(
        x: plate.midX - plate.width * 0.30,
        y: plate.midY - plate.height * 0.30,
        width: plate.width * 0.60,
        height: plate.height * 0.60
    )
    drawSymbol("doc.richtext", in: glyph, weight: .regular, color: .white)
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

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try writeIconSet(named: "AppIcon", into: destination, draw: drawAppIcon)
try writeIconSet(named: "MarkdownDocument", into: destination, draw: drawDocumentIcon)

/// The iOS app icon.
///
/// Full-bleed and square: iOS applies its own rounded-rectangle mask and
/// shadow, so an icon that draws its own rounded plate the way the macOS one
/// does ends up with a visible double edge inside the system's corners.
func drawIOSAppIcon(_ context: CGContext, _ size: CGFloat) {
    let plate = NSRect(x: 0, y: 0, width: size, height: size)

    context.saveGState()
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0x4F / 255, green: 0xB8 / 255, blue: 0xFF / 255, alpha: 1),
            brand,
            brandDark,
        ],
        atLocations: [0, 0.55, 1],
        colorSpace: .sRGB
    )!
    gradient.draw(in: plate, angle: -90)
    context.restoreGState()

    let glyph = NSRect(
        x: plate.midX - plate.width * 0.28,
        y: plate.midY - plate.height * 0.28,
        width: plate.width * 0.56,
        height: plate.height * 0.56
    )
    drawSymbol("doc.richtext", in: glyph, weight: .regular, color: .white)
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
