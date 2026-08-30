#!/usr/bin/env swift

// Checks the pointer shapes the running app shows over a picture.
//
// The pointer is the only part of image editing with no in-process test: it is
// set by AppKit from cursor rects in response to real mouse tracking, so the
// only honest way to check it is to move the real mouse and look at the screen.
//
// Each point is captured twice at the same mouse position, once with the
// pointer composited in (`screencapture -C`) and once without. The difference
// is exactly the pointer, with no background to subtract by guesswork. That
// mask is then compared against every candidate cursor, drawn from the same
// AppKit APIs the app uses, positioned by its own hot spot.
//
// Usage: swift Scripts/check-image-cursors.swift <pid>

import Cocoa

// The system cursors have to be loaded from a real application. Without this,
// `NSCursor.arrow.image` and `NSCursor.iBeam.image` come back as empty 0x0
// images while `pointingHand` and `frameResize` load normally — so those two
// shapes score zero against everything and can never be recognised, and the
// nearest surviving candidate wins instead. This check silently reported
// "pointing hand" for every I-beam it ever saw because of that.
//
// `.prohibited` keeps this helper out of the Dock and stops it taking the
// front from the app being measured.
private let helperApp = NSApplication.shared
helperApp.setActivationPolicy(.prohibited)

let arguments = CommandLine.arguments
guard arguments.count >= 2, let pid = Int(arguments[1]) else {
    print("usage: check-image-cursors.swift <pid>")
    exit(2)
}

var failures: [String] = []
var checks = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    } else {
        print("  FAIL \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
        failures.append(name)
    }
}

// MARK: - Screen capture

@discardableResult
func run(_ launchPath: String, _ args: [String]) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus
}

func capture(region: CGRect, cursor: Bool, to path: String) -> NSBitmapImageRep? {
    try? FileManager.default.removeItem(atPath: path)
    var args = ["-x", "-o"]
    if cursor { args.append("-C") }
    args.append("-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))")
    args.append(path)
    guard run("/usr/sbin/screencapture", args) == 0,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return NSBitmapImageRep(data: data)
}

func documentWindowBounds(pid: Int) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: CGRect?
    for window in list {
        guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
              let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double,
              w > 400, h > 300 else { continue }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
    }
    return best
}

// MARK: - Mouse

func move(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
    Thread.sleep(forTimeInterval: 0.05)
    // A warp alone does not always retrack; a real move event does.
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.45)
}

func click(at point: CGPoint) {
    move(to: point)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.09)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
    // A second release is harmless and stops a swallowed one from turning
    // every later hover into a drag, which silently resizes the picture.
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.5)
}

// MARK: - Masks

struct Mask {
    let width: Int
    let height: Int
    var bits: [Bool]
    func at(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bits[y * width + x]
    }
    var count: Int { bits.reduce(0) { $0 + ($1 ? 1 : 0) } }
}

/// The pointer alone: everything that changed when it was composited in.
func pointerMask(with: NSBitmapImageRep, without: NSBitmapImageRep) -> Mask {
    let w = min(with.pixelsWide, without.pixelsWide)
    let h = min(with.pixelsHigh, without.pixelsHigh)
    var bits = [Bool](repeating: false, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            guard let a = with.colorAt(x: x, y: y), let b = without.colorAt(x: x, y: y) else { continue }
            let d = abs(a.redComponent - b.redComponent)
                + abs(a.greenComponent - b.greenComponent)
                + abs(a.blueComponent - b.blueComponent)
            bits[y * w + x] = d > 0.12
        }
    }
    return Mask(width: w, height: h, bits: bits)
}

/// Where a candidate cursor would land, as a mask in the same pixel grid.
func referenceMask(_ cursor: NSCursor, region: CGRect, mouse: CGPoint, scale: Int, width: Int, height: Int) -> Mask {
    let image = cursor.image
    let size = image.size
    let originX = (mouse.x - cursor.hotSpot.x) - region.minX
    let originY = (mouse.y - cursor.hotSpot.y) - region.minY
    let pw = Int(size.width) * scale
    let ph = Int(size.height) * scale
    guard pw > 0, ph > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
    else { return Mask(width: width, height: height, bits: [Bool](repeating: false, count: width * height)) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()

    var bits = [Bool](repeating: false, count: width * height)
    for y in 0..<ph {
        for x in 0..<pw {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.35 else { continue }
            let dx = Int(originX * Double(scale)) + x
            let dy = Int(originY * Double(scale)) + y
            guard dx >= 0, dy >= 0, dx < width, dy < height else { continue }
            bits[dy * width + dx] = true
        }
    }
    return Mask(width: width, height: height, bits: bits)
}

func intersectionOverUnion(_ a: Mask, _ b: Mask) -> Double {
    var inter = 0, union = 0
    for i in 0..<min(a.bits.count, b.bits.count) {
        if a.bits[i] && b.bits[i] { inter += 1 }
        if a.bits[i] || b.bits[i] { union += 1 }
    }
    return union == 0 ? 0 : Double(inter) / Double(union)
}

// MARK: - Candidate cursors

func diagonalCursor(topLeftToBottomRight: Bool) -> NSCursor {
    let size = NSSize(width: 24, height: 24)
    let image = NSImage(size: size)
    image.lockFocus()
    let path = NSBezierPath()
    let inset: CGFloat = 5
    let a = topLeftToBottomRight ? NSPoint(x: inset, y: size.height - inset) : NSPoint(x: inset, y: inset)
    let b = topLeftToBottomRight ? NSPoint(x: size.width - inset, y: inset) : NSPoint(x: size.width - inset, y: size.height - inset)
    path.move(to: a); path.line(to: b)
    for (tip, other) in [(a, b), (b, a)] {
        let angle = atan2(other.y - tip.y, other.x - tip.x)
        for delta in [0.42, -0.42] as [CGFloat] {
            let t = angle + delta
            path.move(to: tip)
            path.line(to: NSPoint(x: tip.x + cos(t) * 7, y: tip.y + sin(t) * 7))
        }
    }
    NSColor.black.setStroke(); path.lineWidth = 4; path.stroke()
    NSColor.white.setStroke(); path.lineWidth = 2; path.stroke()
    image.unlockFocus()
    return NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
}

struct Candidate { let name: String; let cursor: NSCursor }

/// A candidate whose image will not load matches nothing, scores zero against
/// every sample, and quietly hands the verdict to whichever candidate did
/// load. That is not a failing check, it is a blind one, so say so out loud.
func assertCandidatesAreVisible(_ candidates: [Candidate]) {
    let blind = candidates.filter {
        $0.cursor.image.size.width < 1 || $0.cursor.image.representations.isEmpty
    }
    check(
        "every cursor this check can name is one it can actually see",
        blind.isEmpty,
        blind.isEmpty
            ? ""
            : "no image for: \(blind.map(\.name).joined(separator: ", ")) — results below are meaningless"
    )
}

var candidates: [Candidate] = [
    Candidate(name: "arrow", cursor: .arrow),
    Candidate(name: "I-beam", cursor: .iBeam),
    Candidate(name: "pointing hand", cursor: .pointingHand),
]
if #available(macOS 15.0, *) {
    candidates.append(Candidate(name: "resize ↘", cursor: .frameResize(position: .bottomRight, directions: .all)))
    candidates.append(Candidate(name: "resize ↗", cursor: .frameResize(position: .topRight, directions: .all)))
    candidates.append(Candidate(name: "resize ↙", cursor: .frameResize(position: .bottomLeft, directions: .all)))
    candidates.append(Candidate(name: "resize ↖", cursor: .frameResize(position: .topLeft, directions: .all)))
} else {
    candidates.append(Candidate(name: "resize ↘", cursor: diagonalCursor(topLeftToBottomRight: true)))
    candidates.append(Candidate(name: "resize ↗", cursor: diagonalCursor(topLeftToBottomRight: false)))
}

/// The name of whatever the pointer looks like at `point`, and how sure we are.
func identifyCursor(at point: CGPoint) -> (String, Double, Int) {
    let side: CGFloat = 44
    let region = CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
    move(to: point)
    guard let with = capture(region: region, cursor: true, to: "/tmp/mde-cursor-with.png"),
          let without = capture(region: region, cursor: false, to: "/tmp/mde-cursor-without.png")
    else { return ("capture failed", 0, 0) }
    let mask = pointerMask(with: with, without: without)
    let scale = with.pixelsWide / Int(side)
    var best = ("none", 0.0)
    var scores: [String] = []
    for candidate in candidates {
        let reference = referenceMask(candidate.cursor, region: region, mouse: point,
                                      scale: scale, width: mask.width, height: mask.height)
        let score = intersectionOverUnion(mask, reference)
        scores.append(String(format: "%@ %.2f", candidate.name, score))
        if score > best.1 { best = (candidate.name, score) }
    }
    if ProcessInfo.processInfo.environment["MDE_CURSOR_DEBUG"] == "1" {
        print("       [\(Int(point.x)),\(Int(point.y))] \(mask.count) px — " + scores.joined(separator: "  "))
        try? FileManager.default.copyItem(atPath: "/tmp/mde-cursor-with.png",
                                          toPath: "/tmp/mde-cursor-\(Int(point.x))-\(Int(point.y)).png")
    }
    return (best.0, best.1, mask.count)
}

// MARK: - Locate the picture

let originalMouse = CGPoint(x: NSEvent.mouseLocation.x,
                            y: (NSScreen.screens.first?.frame.height ?? 0) - NSEvent.mouseLocation.y)
func restoreMouse() { CGWarpMouseCursorPosition(originalMouse) }
atexit { }

print("")
print("Pointer shapes over a picture")
assertCandidatesAreVisible(candidates)

// `screencapture -R` reads the screen, not a window, so the app has to be in
// front or the checks measure whatever is covering it.
if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
    app.activate(options: [.activateAllWindows])
    Thread.sleep(forTimeInterval: 1.2)
}

guard let window = documentWindowBounds(pid: pid) else {
    print("  FAIL could not find the document window for pid \(pid)")
    restoreMouse()
    exit(1)
}
print(String(format: "       window (%.0f, %.0f, %.0f, %.0f)", window.minX, window.minY, window.width, window.height))

guard let shot = capture(region: window, cursor: false, to: "/tmp/mde-cursor-window.png") else {
    print("  FAIL could not capture the document window")
    exit(1)
}
let shotScale = Double(shot.pixelsWide) / window.width
func isMarker(_ x: Int, _ y: Int) -> Bool {
    guard let c = shot.colorAt(x: x, y: y) else { return false }
    return c.redComponent > 0.75 && c.greenComponent > 0.25 && c.greenComponent < 0.8 && c.blueComponent < 0.45
}

// The largest blob of marker colour, not the bounding box of every marker
// pixel. The window's own close and minimise buttons are red and yellow, so a
// global bounding box stretches from the title bar to the picture and every
// point derived from it is wrong.
var visited = [Bool](repeating: false, count: shot.pixelsWide * shot.pixelsHigh)
var best = (count: 0, minX: 0, maxX: 0, minY: 0, maxY: 0)
for startY in 0..<shot.pixelsHigh {
    for startX in 0..<shot.pixelsWide {
        let seed = startY * shot.pixelsWide + startX
        guard !visited[seed], isMarker(startX, startY) else { continue }
        visited[seed] = true
        var stack = [(startX, startY)]
        var blob = (count: 0, minX: startX, maxX: startX, minY: startY, maxY: startY)
        while let (x, y) = stack.popLast() {
            blob.count += 1
            blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
            blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < shot.pixelsWide, ny < shot.pixelsHigh else { continue }
                let index = ny * shot.pixelsWide + nx
                guard !visited[index], isMarker(nx, ny) else { continue }
                visited[index] = true
                stack.append((nx, ny))
            }
        }
        if blob.count > best.count { best = blob }
    }
}
let marked = best.count
let (minX, maxX, minY, maxY) = (best.minX, best.maxX, best.minY, best.maxY)
guard marked > 5000 else {
    print("  FAIL no picture found in the window (largest marker blob was \(marked) px)")
    restoreMouse()
    exit(1)
}
let picture = CGRect(x: window.minX + Double(minX) / shotScale,
                     y: window.minY + Double(minY) / shotScale,
                     width: Double(maxX - minX + 1) / shotScale,
                     height: Double(maxY - minY + 1) / shotScale)
print(String(format: "       picture (%.0f, %.0f, %.0f, %.0f)", picture.minX, picture.minY, picture.width, picture.height))

// MARK: - Checks

// The first capture after activating tends to come back without a pointer;
// take a throwaway reading before anything is asserted.
_ = identifyCursor(at: CGPoint(x: picture.midX, y: picture.midY))

let textPoint = CGPoint(x: picture.minX + 40, y: picture.minY - 40)
let (textCursor, textScore, textPixels) = identifyCursor(at: textPoint)
check("the pointer over text is an I-beam", textCursor == "I-beam",
      String(format: "saw %@ (%.2f, %d px)", textCursor, textScore, textPixels))

let centre = CGPoint(x: picture.midX, y: picture.midY)
let (bodyCursor, bodyScore, bodyPixels) = identifyCursor(at: centre)
check("the pointer over the picture is an arrow", bodyCursor == "arrow",
      String(format: "saw %@ (%.2f, %d px)", bodyCursor, bodyScore, bodyPixels))

click(at: centre)

let corners: [(String, CGPoint, [String])] = [
    ("top-left", CGPoint(x: picture.minX, y: picture.minY), ["resize ↖", "resize ↘"]),
    ("top-right", CGPoint(x: picture.maxX, y: picture.minY), ["resize ↗", "resize ↙"]),
    ("bottom-left", CGPoint(x: picture.minX, y: picture.maxY), ["resize ↙", "resize ↗"]),
    ("bottom-right", CGPoint(x: picture.maxX, y: picture.maxY), ["resize ↘", "resize ↖"]),
]
for (name, point, expected) in corners {
    let (seen, score, pixels) = identifyCursor(at: point)
    check("the pointer on the \(name) handle is a diagonal resize", expected.contains(seen),
          String(format: "saw %@ (%.2f, %d px)", seen, score, pixels))
}

let (bodyAgain, bodyAgainScore, _) = identifyCursor(at: centre)
check("the pointer between the handles is still an arrow", bodyAgain == "arrow",
      String(format: "saw %@ (%.2f)", bodyAgain, bodyAgainScore))

restoreMouse()

print("")
if failures.isEmpty {
    print("ALL PASS (\(checks) checks)")
} else {
    print("\(failures.count) of \(checks) checks failed")
    exit(1)
}
