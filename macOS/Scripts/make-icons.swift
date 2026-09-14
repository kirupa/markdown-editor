// Generates the app and document icons.
//
// Run with `make icons`, which writes `Packaging/AppIcon.icns`,
// `Packaging/MarkdownDocument.icns` and the iOS app icon. The results are
// committed, so a normal build does not need to run this.
//
// The app icon is `Packaging/Logo.svg` — the kirupa mark — on white. The
// document icon is drawn with Core Graphics. Nothing here needs an asset
// pipeline or a design tool: AppKit rasterises the SVG and `iconutil` packs
// the result, and both ship with macOS.

import AppKit
import Foundation

let brand = NSColor(srgbRed: 0x07 / 255, green: 0x98 / 255, blue: 0xFF / 255, alpha: 1)

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

/// The kirupa mark, and where its visible ink sits inside its own square.
///
/// The ink box is measured rather than written down, because the artwork is
/// neither centred in its viewBox nor filling it: drawn as a plain square the
/// mark comes out small and visibly off to one side. Measuring means the next
/// logo dropped in here is placed correctly without anybody re-deriving a
/// number.
struct Logo {
    let image: NSImage
    /// The ink's bounds as fractions of the image, y measured from the bottom.
    let ink: NSRect

    /// Draws the mark so its **ink** is centred in `rect` and its longer side
    /// is `fill` of that rect.
    ///
    /// Fitting the ink rather than the image is the whole point: white is not
    /// ink here. The logo carries a white halo and a white disc behind the
    /// fruit, which are invisible on a white plate, so sizing to the image
    /// would silently reserve room for something nobody can see.
    func draw(in rect: NSRect, fill: CGFloat) {
        let side = rect.width * fill / max(ink.width, ink.height)
        let origin = NSPoint(
            x: rect.midX - ink.midX * side,
            y: rect.midY - ink.midY * side
        )
        image.draw(
            in: NSRect(origin: origin, size: NSSize(width: side, height: side)),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }
}

/// The rounded-rectangle app icon: the kirupa mark on a white plate, inset to
/// match the macOS icon grid.
func drawAppIcon(_ context: CGContext, _ size: CGFloat, logo: Logo) {
    let inset = size * 0.086
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plate.width * 0.2237
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    context.saveGState()
    path.addClip()
    NSColor.white.setFill()
    plate.fill()
    context.restoreGState()

    logo.draw(in: plate, fill: 0.80)
}

/// The logo, read from the SVG beside the icons it is drawn into.
///
/// AppKit rasterises SVG itself — `NSImage` hands back an `_NSSVGImageRep`,
/// which redraws at whatever size it is asked for — so the 16pt icon and the
/// 512@2x one are both drawn from the vector rather than resampled from one
/// bitmap. That is the whole reason the source art is an SVG here and not a
/// PNG: this script renders ten sizes spanning 16 to 1024 pixels.
func loadLogo(from directory: URL) throws -> Logo {
    let url = directory.appendingPathComponent("Logo.svg")
    guard let image = NSImage(contentsOf: url) else {
        throw NSError(
            domain: "make-icons",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No logo at \(url.path)"]
        )
    }
    return Logo(image: image, ink: inkBounds(of: image))
}

/// Where a mark's visible ink sits inside its own square, as fractions.
///
/// Rendered large and scanned. Transparent pixels are not ink, and neither is
/// white: on a white plate the logo's halo is invisible, so counting it would
/// push the part a person can actually see off centre — measured at 3.5pt
/// across and 5pt down on a 512pt canvas before this existed.
func inkBounds(of image: NSImage) -> NSRect {
    let probe = 512
    let rep = makeBitmap(size: probe) { _, size in
        image.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high.rawValue]
        )
    }

    var minX = probe, minY = probe, maxX = -1, maxY = -1
    for y in 0..<probe {
        for x in 0..<probe {
            guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5
            else { continue }
            let isWhite = colour.redComponent > 0.97
                && colour.greenComponent > 0.97
                && colour.blueComponent > 0.97
            guard !isWhite else { continue }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else {
        return NSRect(x: 0, y: 0, width: 1, height: 1)
    }

    // `colorAt` counts rows from the top; the drawing above does not.
    let side = CGFloat(probe)
    return NSRect(
        x: CGFloat(minX) / side,
        y: CGFloat(probe - 1 - maxY) / side,
        width: CGFloat(maxX - minX + 1) / side,
        height: CGFloat(maxY - minY + 1) / side
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

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let logo = try loadLogo(from: destination)
try writeIconSet(named: "AppIcon", into: destination) { context, size in
    drawAppIcon(context, size, logo: logo)
}
try writeIconSet(named: "MarkdownDocument", into: destination, draw: drawDocumentIcon)

/// The iOS app icon.
///
/// Full-bleed and square: iOS applies its own rounded-rectangle mask and
/// shadow, so an icon that draws its own rounded plate the way the macOS one
/// does ends up with a visible double edge inside the system's corners.
func drawIOSAppIcon(_ context: CGContext, _ size: CGFloat, logo: Logo) {
    let plate = NSRect(x: 0, y: 0, width: size, height: size)

    NSColor.white.setFill()
    plate.fill()

    // Tighter than the Mac's 0.80 because this square has no plate inside
    // it: iOS rounds the corners off the artwork itself, so the same fraction
    // would put the mark hard against the visible edge.
    logo.draw(in: plate, fill: 0.62)
}

/// Writes the single 1024×1024 PNG an iOS asset catalog expects.
func writeIOSAppIcon(into appIconSet: URL, logo: Logo) throws {
    let representation = makeBitmap(size: 1024) { context, size in
        drawIOSAppIcon(context, size, logo: logo)
    }
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
        into: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
        logo: logo
    )
}
