#!/usr/bin/env swift

// Runtime checks for where an image really is on screen.
//
// The arithmetic lives in `EditorImageGeometry` and is unit-tested in the
// shared package. What a unit test cannot answer is the question the whole
// change turns on: *which* rect AppKit means. `boundingRect(forGlyphRange:)`
// is the obvious way to locate an attachment and it is the wrong one — it
// returns the glyph's line box, which on a line holding anything taller than
// the picture includes blank space above and below it. Selecting from that
// rect accepts clicks in the margin and draws the frame around nothing.
//
// So these checks lay out a real NSTextView, render it to a bitmap, and find
// the image by its pixels. The drawn rect is the ground truth, and both
// formulas are measured against it. Run with `make check-image-handles`.
// Exits non-zero on the first failure.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Harness

var failures = 0
var checks = 0

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

func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1.0) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - Fixture

/// A colour that appears nowhere else, so the image can be found by looking.
let marker = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)

let imageSize = NSSize(width: 120, height: 40)
let swatch = NSImage(size: imageSize)
swatch.lockFocus()
marker.setFill()
NSRect(origin: .zero, size: imageSize).fill()
swatch.unlockFocus()

let attachment = NSTextAttachment()
attachment.image = swatch
attachment.bounds = CGRect(origin: .zero, size: imageSize)

let paragraph = NSMutableParagraphStyle()
// Line spacing is the point: it pads the line box without moving the picture.
paragraph.lineSpacing = 14

let storage = NSMutableAttributedString()
storage.append(
    NSAttributedString(
        string: "Tall ",
        attributes: [
            // A font far larger than the image, so the line box cannot help
            // but be taller than the attachment.
            .font: NSFont.systemFont(ofSize: 64),
            .paragraphStyle: paragraph
        ]
    )
)
let attachmentString = NSMutableAttributedString(attachment: attachment)
attachmentString.addAttribute(
    .paragraphStyle,
    value: paragraph,
    range: NSRange(location: 0, length: attachmentString.length)
)
storage.append(attachmentString)

let attachmentIndex = storage.length - 1

let frame = NSRect(x: 0, y: 0, width: 600, height: 300)
let textView = NSTextView(frame: frame)
textView.textContainerInset = .zero
textView.textContainer?.lineFragmentPadding = 0
textView.textContainer?.containerSize = NSSize(
    width: frame.width,
    height: .greatestFiniteMagnitude
)
textView.textContainer?.widthTracksTextView = false
textView.isRichText = true
textView.drawsBackground = true
textView.backgroundColor = .white
textView.textStorage?.setAttributedString(storage)

// A view with no window does not always draw its attachments, so give it one.
// Off screen and never ordered front — this is a measurement, not a UI.
let window = NSWindow(
    contentRect: frame,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.contentView = textView
window.orderBack(nil)

guard
    let layoutManager = textView.layoutManager,
    let container = textView.textContainer
else {
    print("no layout manager")
    exit(1)
}
layoutManager.ensureLayout(for: container)

// MARK: - The two candidate rects

let characterRange = NSRange(location: attachmentIndex, length: 1)
let glyphRange = layoutManager.glyphRange(
    forCharacterRange: characterRange,
    actualCharacterRange: nil
)
let origin = textView.textContainerOrigin

var lineBoxRect = layoutManager.boundingRect(
    forGlyphRange: glyphRange,
    in: container
)
lineBoxRect.origin.x += origin.x
lineBoxRect.origin.y += origin.y

let fragment = layoutManager.lineFragmentRect(
    forGlyphAt: glyphRange.location,
    effectiveRange: nil
)
let glyphLocation = layoutManager.location(forGlyphAt: glyphRange.location)
// The same expression as EditorImageGeometry.attachmentRect, spelled out here
// because a script cannot import the package. Note what it does *not* use:
// `attachment.bounds.origin`. See the offset checks at the end.
let tightRect = CGRect(
    x: fragment.minX + glyphLocation.x + origin.x,
    y: fragment.minY + glyphLocation.y - attachment.bounds.height + origin.y,
    width: attachment.bounds.width,
    height: attachment.bounds.height
)

// MARK: - Ground truth: where the marker colour actually landed

func drawnImageBounds() -> CGRect? {
    guard
        let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds)
    else { return nil }
    textView.cacheDisplay(in: textView.bounds, to: rep)

    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            let srgb = colour.usingColorSpace(.sRGB) ?? colour
            // Loose thresholds on purpose. The window's colour profile shifts
            // pure magenta on the way to the bitmap, so an exact match finds
            // nothing. This still separates it unambiguously from the white
            // background and the black text, which is all it has to do.
            guard
                srgb.redComponent > 0.7,
                srgb.greenComponent < 0.6,
                srgb.blueComponent > 0.7
            else { continue }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
    guard minX <= maxX, minY <= maxY else { return nil }
    // The rep is in pixels; the view is in points.
    let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
    return CGRect(
        x: CGFloat(minX) / scale,
        y: CGFloat(minY) / scale,
        width: CGFloat(maxX - minX + 1) / scale,
        height: CGFloat(maxY - minY + 1) / scale
    )
}

print("Image rect")
guard let drawn = drawnImageBounds() else {
    print("  FAIL the image never drew — nothing to measure against")
    exit(1)
}

check(
    "the picture drew at the size it was given",
    near(drawn.width, imageSize.width, 2) && near(drawn.height, imageSize.height, 2),
    "drawn \(drawn.size), expected \(imageSize)"
)

check(
    "the tight rect is where the picture actually is",
    near(tightRect.minX, drawn.minX) && near(tightRect.minY, drawn.minY)
        && near(tightRect.width, drawn.width) && near(tightRect.height, drawn.height),
    "computed \(tightRect), drawn \(drawn)"
)

// If this ever fails, AppKit has started returning the tight rect and the
// whole reason for computing one by hand has gone away.
check(
    "the line box really is the wrong rect",
    lineBoxRect.height > drawn.height + 4,
    "line box \(lineBoxRect) is no taller than the picture \(drawn)"
)

let strayAbove = drawn.minY - lineBoxRect.minY
let strayBelow = lineBoxRect.maxY - drawn.maxY
check(
    "the line box claims blank space the pointer would have accepted",
    strayAbove > 1 || strayBelow > 1,
    "above \(strayAbove), below \(strayBelow)"
)

// MARK: - What that means for the pointer

// A point in the line box but outside the picture: the bug, expressed as a
// click. It has to miss.
let strayPoint = CGPoint(
    x: drawn.midX,
    y: strayAbove > 1 ? lineBoxRect.minY + 1 : lineBoxRect.maxY - 1
)
check(
    "a click above or below the picture is not a click on it",
    !tightRect.contains(strayPoint) && lineBoxRect.contains(strayPoint),
    "stray \(strayPoint) tight \(tightRect) line \(lineBoxRect)"
)

check(
    "a click in the middle of the picture is a click on it",
    tightRect.contains(CGPoint(x: drawn.midX, y: drawn.midY))
)

// MARK: - The cursor AppKit hands back

// The point of the arrow cursor is that it is not the I-beam. Asking NSCursor
// for both and comparing is the only way to be sure they differ at all.
check(
    "the arrow and the I-beam are different cursors",
    NSCursor.arrow != NSCursor.iBeam
)

if #available(macOS 15.0, *) {
    let corners: [(String, NSCursor)] = [
        ("topLeft", .frameResize(position: .topLeft, directions: .all)),
        ("topRight", .frameResize(position: .topRight, directions: .all)),
        ("bottomLeft", .frameResize(position: .bottomLeft, directions: .all)),
        ("bottomRight", .frameResize(position: .bottomRight, directions: .all))
    ]
    check(
        "every corner cursor differs from the arrow",
        corners.allSatisfy { $0.1 != NSCursor.arrow }
    )
    // The two diagonals must differ from each other, or a corner cursor is
    // telling the user the wrong direction.
    check(
        "the two diagonals are not the same cursor",
        corners[0].1 != corners[1].1,
        "topLeft and topRight resolved to the same cursor"
    )
    check(
        "opposite corners share a diagonal",
        corners[0].1 == corners[3].1 && corners[1].1 == corners[2].1
    )
}

// MARK: - What a baseline offset does, and does not, do

// The rule the rect depends on, measured rather than assumed.
//
// `NSTextAttachment.bounds.origin` reads like an offset to apply, and applying
// it is wrong: the layout manager has already folded it into the glyph location
// by the time anyone asks. Getting this backwards is a silent error exactly the
// size of the offset — the renderer sets -4, so every handle sat 4pt below the
// corner it was holding and the frame hung off the bottom of the picture.
//
// If this ever fails, TextKit has changed which corner it reports and
// EditorImageGeometry.attachmentRect has to change with it.

print("")
print("Baseline offset")

func drawnTop(forOffset offsetY: CGFloat, offsetX: CGFloat) -> (drawn: CGRect, location: CGPoint, fragment: CGRect, origin: CGPoint)? {
    let probeAttachment = NSTextAttachment()
    probeAttachment.image = swatch
    probeAttachment.bounds = CGRect(
        x: offsetX,
        y: offsetY,
        width: imageSize.width,
        height: imageSize.height
    )
    let probeStorage = NSMutableAttributedString()
    probeStorage.append(
        NSAttributedString(
            string: "Tall ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 64),
                .paragraphStyle: paragraph
            ]
        )
    )
    let piece = NSMutableAttributedString(attachment: probeAttachment)
    piece.addAttribute(
        .paragraphStyle,
        value: paragraph,
        range: NSRange(location: 0, length: piece.length)
    )
    probeStorage.append(piece)
    textView.textStorage?.setAttributedString(probeStorage)
    guard let probeContainer = textView.textContainer else { return nil }
    textView.layoutManager?.ensureLayout(for: probeContainer)

    let index = probeStorage.length - 1
    guard let manager = textView.layoutManager else { return nil }
    let probeGlyphs = manager.glyphRange(
        forCharacterRange: NSRange(location: index, length: 1),
        actualCharacterRange: nil
    )
    guard let bounds = drawnImageBounds() else { return nil }
    return (
        bounds,
        manager.location(forGlyphAt: probeGlyphs.location),
        manager.lineFragmentRect(forGlyphAt: probeGlyphs.location, effectiveRange: nil),
        textView.textContainerOrigin
    )
}

for offset in [CGFloat(0), -4, 12, -20] {
    guard let probe = drawnTop(forOffset: offset, offsetX: 0) else {
        check("offset \(offset) drew", false)
        continue
    }
    let predicted = probe.fragment.minY + probe.location.y
        - imageSize.height + probe.origin.y
    check(
        "a vertical offset of \(Int(offset))pt is already in the glyph location",
        near(predicted, probe.drawn.minY),
        "predicted \(predicted), drawn \(probe.drawn.minY)"
    )
}

for offset in [CGFloat(0), 8, 25] {
    guard let probe = drawnTop(forOffset: 0, offsetX: offset) else {
        check("x offset \(offset) drew", false)
        continue
    }
    let predicted = probe.fragment.minX + probe.location.x + probe.origin.x
    check(
        "a horizontal offset of \(Int(offset))pt is already in the glyph location",
        near(predicted, probe.drawn.minX),
        "predicted \(predicted), drawn \(probe.drawn.minX)"
    )
}

print("")
if failures == 0 {
    print("ALL PASS (\(checks) checks)")
    exit(0)
}
print("\(failures) of \(checks) checks failed")
exit(1)
