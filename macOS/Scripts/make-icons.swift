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

/// The kirupa mark: the circle that sizes it, and the point it balances on.
struct Logo {
    let image: NSImage
    /// The circular outline's bounds as fractions of the image, y measured
    /// from the bottom. What the icon is **sized** by.
    let anchor: NSRect
    /// The dark mark's centre of gravity, in the same fractions. What the icon
    /// is **centred** by.
    let opticalCentre: CGPoint

    /// Draws the mark so it balances on `rect`'s centre, with the circle's
    /// diameter `fill` of the rect.
    ///
    /// Sized by the circle and centred by what the circle holds, because those
    /// are two different questions and one answer does not serve both.
    ///
    /// Centring on the circle's *geometry* measures perfect and still looks
    /// wrong. The ring is not closed — the leaves cross it and leave a 40° gap
    /// from 9 to 11 o'clock — so the dark shape on screen is a C rather than an
    /// O, and a C weighs more on the side away from its opening. The eye reads
    /// the weight, not the bounding box.
    ///
    /// Correcting all the way to the dark ring's own centre of mass overshoots:
    /// it drags the whole mark up and left until the leaves crowd the plate's
    /// corner and a visibly empty quarter opens opposite. Rendered side by side
    /// that reads worse than the error it fixes. What balances is the ink the
    /// circle *encloses* — the ring and the fruit inside it, which is the round
    /// object being centred — while the leaves stay an accent that is allowed
    /// to overhang. An accent that drags the composition is not an accent.
    func draw(in rect: NSRect, fill: CGFloat) {
        let side = rect.width * fill / max(anchor.width, anchor.height)
        let origin = NSPoint(
            x: rect.midX - opticalCentre.x * side,
            y: rect.midY - opticalCentre.y * side
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

    logo.draw(in: plate, fill: 0.66)
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
    let mark = measureMark(in: image)
    return Logo(
        image: image,
        anchor: mark.outline,
        opticalCentre: mark.centreOfGravity
    )
}

/// The mark's circular outline and its centre of gravity, both as fractions of
/// the artwork's own square, y measured from the bottom.
///
/// Measured rather than written down. The artwork is neither centred in its
/// viewBox nor filling it, so every number here would otherwise be a constant
/// nobody could check — and the next mark dropped in would need all of them
/// re-derived by hand.
///
/// The outline is found as ink that is dark **and** near-neutral. Dark alone
/// does not do it: the leaves are `#008000`, which is darker than the
/// `#333333` ring, so a brightness test alone drags the box back out to the
/// top-left corner. Saturation is what separates a drawn outline from coloured
/// artwork.
///
/// Measured on this logo the circle comes back 0.713 square with its bounds
/// centred at (0.540, 0.520), while the ink it encloses balances at (0.545,
/// 0.535). Both numbers are needed: the bounds size the mark, the balance
/// point places it.
///
/// Falls back to every non-white pixel when a mark has no such outline. White
/// is not ink either way: this logo carries a white halo and a white disc that
/// are invisible on a white plate, and counting them reserves room for
/// something nobody can see.
func measureMark(in image: NSImage) -> (outline: NSRect, centreOfGravity: CGPoint) {
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

    var outline = Box(), ink = Box()
    var inkPixels: [(x: Int, y: Int)] = []
    for y in 0..<probe {
        for x in 0..<probe {
            guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.5
            else { continue }
            let highest = max(colour.redComponent, max(colour.greenComponent, colour.blueComponent))
            let lowest = min(colour.redComponent, min(colour.greenComponent, colour.blueComponent))
            guard highest < 0.97 || lowest < 0.97 else { continue }
            ink.add(x: x, y: y)
            inkPixels.append((x, y))

            let saturation = highest > 0 ? (highest - lowest) / highest : 0
            if saturation < 0.25, highest < 0.45 {
                outline.add(x: x, y: y)
            }
        }
    }

    let box = outline.isEmpty ? ink : outline
    let bounds = box.normalized(in: probe)

    // The circle inscribed in those bounds, in pixels, and the ink inside it.
    let side = CGFloat(probe)
    let centreX = bounds.midX * side
    let centreY = (1 - bounds.midY) * side
    let radius = max(bounds.width, bounds.height) * side / 2
    var enclosed = Box()
    for pixel in inkPixels {
        let dx = CGFloat(pixel.x) + 0.5 - centreX
        let dy = CGFloat(pixel.y) + 0.5 - centreY
        if (dx * dx + dy * dy).squareRoot() <= radius {
            enclosed.add(x: pixel.x, y: pixel.y)
        }
    }

    let balance = enclosed.isEmpty ? box : enclosed
    return (bounds, balance.centreOfGravity(in: probe))
}

/// Ink accumulated a pixel at a time, in top-down image rows: both the box
/// around it and where its weight falls.
struct Box {
    private var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    private var sumX = 0, sumY = 0, count = 0

    var isEmpty: Bool { maxX < minX }

    mutating func add(x: Int, y: Int) {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
        sumX += x; sumY += y; count += 1
    }

    /// The mean position of the ink, in the same fractions `normalized` uses.
    ///
    /// Every pixel counts once. That is the point: a gap in the outline is
    /// pixels that are not there, and their absence is exactly what shifts the
    /// shape's weight off the centre its geometry claims.
    func centreOfGravity(in side: Int) -> CGPoint {
        guard count > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let side = CGFloat(side)
        return CGPoint(
            x: (CGFloat(sumX) / CGFloat(count) + 0.5) / side,
            y: (side - 1 - CGFloat(sumY) / CGFloat(count) + 0.5) / side
        )
    }

    /// As fractions of a `side`-pixel square, with y flipped to run from the
    /// bottom — `colorAt` counts rows from the top, and drawing does not.
    func normalized(in side: Int) -> NSRect {
        guard !isEmpty else { return NSRect(x: 0, y: 0, width: 1, height: 1) }
        let side = CGFloat(side)
        return NSRect(
            x: CGFloat(minX) / side,
            y: (side - 1 - CGFloat(maxY)) / side,
            width: CGFloat(maxX - minX + 1) / side,
            height: CGFloat(maxY - minY + 1) / side
        )
    }
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

    // Tighter than the Mac's 0.66 because this square has no plate inside
    // it: iOS rounds the corners off the artwork itself, so the same fraction
    // would put the mark hard against the visible edge.
    logo.draw(in: plate, fill: 0.51)
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

/// The web icon: the same mark on the same white plate, written as an SVG.
///
/// Generated rather than hand-drawn, for the reason the bitmaps are. The plate
/// geometry and where the mark sits on it are one decision, and a second copy
/// of that decision in a hand-written file is a copy that will disagree — the
/// file this replaces still carried the old blue plate months after the Mac
/// icon had one drawn from constants.
///
/// Self-contained on purpose: a browser renders an SVG favicon in a restricted
/// mode that fetches no external resources, so the mark is inlined rather than
/// referenced. That also makes it usable as an `<img>` on the welcome screen,
/// which is how the web build reaches what macOS gets from
/// `NSImage.applicationIconName` — one icon in the tab, on the landing screen,
/// and on a home screen.
func writeWebIcon(into directory: URL, logo: Logo, source: URL) throws {
    let canvas: CGFloat = 64
    let inset = canvas * 0.086
    let plate = NSRect(
        x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2
    )

    // The arithmetic `Logo.draw` does, in SVG user units. `opticalCentre`
    // measures y from the bottom and SVG measures it from the top, which is
    // the one place the two coordinate systems have to be reconciled by hand.
    let side = plate.width * 0.66 / max(logo.anchor.width, logo.anchor.height)
    let scale = side / logo.image.size.width
    let anchorX = logo.opticalCentre.x * logo.image.size.width
    let anchorY = (1 - logo.opticalCentre.y) * logo.image.size.height
    let x = canvas / 2 - anchorX * scale
    let y = canvas / 2 - anchorY * scale

    let markup = try String(contentsOf: source, encoding: .utf8)
    guard let openEnd = markup.range(of: ">"),
        let closeStart = markup.range(of: "</svg>", options: .backwards)
    else {
        throw NSError(
            domain: "make-icons",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "\(source.path) is not an SVG"]
        )
    }
    let inner = markup[openEnd.upperBound..<closeStart.lowerBound]
        .trimmingCharacters(in: .whitespacesAndNewlines)

    func round(_ value: CGFloat) -> String {
        String(format: "%.4g", value)
    }

    let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" \
        xmlns:xlink="http://www.w3.org/1999/xlink" \
        viewBox="0 0 \(Int(canvas)) \(Int(canvas))" role="img" aria-label="KONVO">
        <!-- Generated by macOS/Scripts/make-icons.swift. Do not edit. -->
        <rect x="\(round(plate.minX))" y="\(round(plate.minY))" \
        width="\(round(plate.width))" height="\(round(plate.height))" \
        rx="\(round(plate.width * 0.2237))" fill="#FFFFFF"/>
        <g transform="translate(\(round(x)) \(round(y))) scale(\(round(scale)))">
        \(inner)
        </g>
        </svg>

        """

    let file = directory.appendingPathComponent("icon.svg")
    try svg.write(to: file, atomically: true, encoding: .utf8)
    print("Wrote \(file.path)")
}

if CommandLine.arguments.count > 3 {
    try writeWebIcon(
        into: URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true),
        logo: logo,
        source: destination.appendingPathComponent("Logo.svg")
    )
}
