// An end-to-end check of the critique path, against the real CLI.
//
// Everything else about this feature can be checked offline: decoding has
// fixtures, anchoring has drafts. What none of that can tell you is whether a
// *real* reply from a *real* model still decodes, and — the part that actually
// breaks — whether the quotes it returns can still be found in the draft. That
// is a property of the prompt, not of the parser, and the only way to know is
// to ask.
//
// It costs AI credits and about half a minute, so it is not part of `make
// test`. Run it after changing the prompt, the decoder, or the anchoring.
//
// Built by Scripts/run-critique-checks.sh against the real app sources.

import AppKit
import Foundation
import SwiftUI
import MarkdownEditorCore
import MarkdownEditorUI

@MainActor private var failures = 0
@MainActor private var checks = 0

@MainActor
func check(_ label: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if passed {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

/// A draft with problems planted in it that a critique should be able to name,
/// each one a different category so the run exercises more than one path.
let draft = """
    # Understanding Caching

    Caching is a very important technique that every developer should know \
    about. In today's fast-paced world of software development, caching has \
    become absolutely essential.

    The way caching works is that it stores data. When you need the data \
    again, you get it from the cache instead. This makes things faster.

    Studies show that caching improves performance by 90%. There are many \
    types of caches and each one has it own tradeoffs.

    In conclusion, caching is a powerful tool that can help you build better \
    applications.
    """

/// The part of this feature that lives in the view: a passage is shaded where
/// the critique says it is, and clicking it reports the right comment.
///
/// Needs no CLI, no credits, and no screen — it reads the temporary attributes
/// the view actually holds and hit-tests real points — so it runs every time.
@MainActor
func checkHighlightsAndClicking() {
    print("Shading the passages a critique points at")

    let source = """
        # Understanding Caching

        Caching is important because the cache stores data for later reads.

        Studies show that caching improves performance by 90%.
        """
    let model = MarkdownRenderer.render(source)
    let styled = RichMarkdownStyler.attributedString(
        for: model,
        documentURL: nil,
        colorTheme: EditorColorTheme(color: .blue, mode: .light)
    )

    let frame = NSRect(x: 0, y: 0, width: 700, height: 500)
    let view = RichMarkdownTextView(frame: frame)
    view.textContainerInset = NSSize(width: 24, height: 20)
    view.textContainer?.containerSize = NSSize(
        width: frame.width - 48, height: .greatestFiniteMagnitude
    )
    view.textContainer?.widthTracksTextView = true
    view.isVerticallyResizable = true
    view.drawsBackground = true
    view.backgroundColor = .white
    view.textStorage?.setAttributedString(styled)
    let window = NSWindow(
        contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = view
    window.orderBack(nil)
    view.layoutSubtreeIfNeeded()
    view.layoutManager?.ensureLayout(for: view.textContainer!)

    // Two findings, quoting passages that really are in the draft.
    let findings = [
        CritiqueFinding(
            severity: .high, category: "Logic and credibility",
            location: "paragraph 3",
            // Reaches the end of its line on purpose: the margin check below
            // needs the nearest glyph to a far-right click to be one that is
            // actually shaded, or it passes whether or not the guard exists.
            quote: "Studies show that caching improves performance by 90%.",
            why: "No citation."
        ),
        CritiqueFinding(
            severity: .low, category: "Clarity and precision",
            location: "paragraph 2",
            quote: "the cache stores data", why: "Vague."
        ),
    ]
    let anchors = CritiqueAnchoring.anchor(findings, in: source)
    check(
        "both quotes anchor in the source",
        anchors.allSatisfy(\.isAnchored),
        "\(anchors.filter(\.isAnchored).count) of 2"
    )

    // The conversion the pane has to make: a critique is written about the
    // Markdown, and this view shows it with the syntax taken out.
    var highlights: [RichMarkdownTextView.CritiqueHighlight] = []
    for (anchor, finding) in zip(anchors, findings) {
        guard let sourceRange = anchor.range else { continue }
        let rendered = model.renderedRange(for: sourceRange)
        let shown = (view.string as NSString).substring(with: rendered)
        check(
            "\"\(finding.quote)\" maps onto the same words in the rendered pane",
            shown == finding.quote,
            "rendered as \"\(shown)\""
        )
        highlights.append(
            .init(id: finding.id, range: rendered, colour: finding.severity.highlight)
        )
    }
    view.critiqueHighlights = highlights

    // The shading is a *temporary* attribute, so it cannot end up in the
    // document or in a copy. Read it back from the layout manager.
    guard let layoutManager = view.layoutManager else {
        check("the view has a layout manager", false)
        return
    }
    for (highlight, finding) in zip(highlights, findings) {
        let colour = layoutManager.temporaryAttribute(
            .backgroundColor,
            atCharacterIndex: highlight.range.location,
            effectiveRange: nil
        ) as? NSColor
        check(
            "the \(finding.severity.rawValue) passage is shaded",
            colour != nil,
            "no background attribute at \(highlight.range.location)"
        )
    }
    let outside = layoutManager.temporaryAttribute(
        .backgroundColor, atCharacterIndex: 0, effectiveRange: nil
    )
    check("the heading is left alone", outside == nil)

    check(
        "shading never reaches the text storage",
        view.textStorage?.attribute(
            .backgroundColor,
            at: highlights[0].range.location,
            effectiveRange: nil
        ) == nil,
        "a copied passage would carry the highlight with it"
    )

    // Clicking a shaded passage has to raise its own comment. This is the
    // interaction the whole rail rests on, and the failure — reporting the
    // wrong finding — looks exactly like a working feature.
    // The rail sits beside the text, so reading down the comments has to mean
    // reading down the draft. Ordering by severity instead would put the first
    // card next to the last paragraph, which is the thing that makes a rail
    // feel like a list that happens to be on the right.
    print("")
    print("Ordering the rail")
    let model2 = CritiqueModel()
    model2.applyForChecking(
        CritiqueReport(
            jobRead: "", overall: "",
            // Deliberately worst-last in the report, and last-first in the
            // draft, so severity order and reading order disagree.
            findings: [findings[0], findings[1]]
        ),
        for: source
    )
    let positions = model2.items.compactMap { $0.range?.location }
    check(
        "cards read down the draft, not by severity",
        positions == positions.sorted(),
        "positions \(positions)"
    )
    check(
        "and the low finding, which comes first in the text, is first",
        model2.items.first?.finding.severity == .low,
        "\(model2.items.first?.finding.severity.rawValue ?? "none") was first"
    )
    check(
        "severity is still legible as a count",
        model2.severityCounts.count == 2,
        "\(model2.severityCounts.count) severities counted"
    )

    print("")
    print("Clicking a shaded passage")
    var clicked: UUID?
    view.didClickCritiqueHighlight = { clicked = $0 }

    for (highlight, finding) in zip(highlights, findings) {
        let box = layoutManager.boundingRect(
            forGlyphRange: layoutManager.glyphRange(
                forCharacterRange: highlight.range, actualCharacterRange: nil
            ),
            in: view.textContainer!
        )
        let point = CGPoint(
            x: box.midX + view.textContainerInset.width,
            y: box.midY + view.textContainerInset.height
        )
        clicked = nil
        view.raiseCritiqueComment(at: point)
        check(
            "clicking the \(finding.severity.rawValue) passage raises its own comment",
            clicked == finding.id,
            clicked == nil ? "nothing was raised" : "raised a different comment"
        )
    }

    // And a click on ordinary text must raise nothing, or every click in the
    // document would change which comment is open.
    clicked = nil
    let headingBox = layoutManager.boundingRect(
        forGlyphRange: NSRange(location: 0, length: 1), in: view.textContainer!
    )
    let headingPoint = CGPoint(
        x: headingBox.midX + view.textContainerInset.width,
        y: headingBox.midY + view.textContainerInset.height
    )
    view.raiseCritiqueComment(at: headingPoint)
    check("clicking unshaded text raises nothing", clicked == nil)

    // Far outside the text, the nearest glyph is still *some* glyph. Without
    // checking the glyph's own box, a click in the margin would open whatever
    // comment happened to be on that line — so the point has to be level with
    // a shaded passage and past the end of it, which is exactly the case that
    // looks like a working feature when it is wrong.
    clicked = nil
    let shadedBox = layoutManager.boundingRect(
        forGlyphRange: layoutManager.glyphRange(
            forCharacterRange: highlights[0].range, actualCharacterRange: nil
        ),
        in: view.textContainer!
    )
    view.raiseCritiqueComment(
        at: CGPoint(
            x: frame.width - 6,
            y: shadedBox.midY + view.textContainerInset.height
        )
    )
    check(
        "clicking the margin level with a shaded passage raises nothing",
        clicked == nil,
        "the margin opened a comment"
    )
}

@main
@MainActor
struct CheckCritique {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        checkHighlightsAndClicking()
        checkTheRailRenders()

        // The live half costs credits and half a minute. Everything above is
        // free, so it runs either way.
        if CommandLine.arguments.contains("--offline") {
            print("")
            print("Skipping the live critique (--offline)")
            finish()
        }

        print("")
        print("Locating the CLI")
        guard let cli = CritiqueService.locateCLI() else {
            print("  FAIL the Copilot CLI was not found on PATH or in the SDK cache")
            print("\n1 of 1 checks failed")
            exit(1)
        }
        check("found the Copilot CLI", true, cli.path)

        print("")
        print("Running a real critique (this costs credits and takes ~30s)")
        let service = CritiqueService()
        let report: CritiqueReport
        do {
            report = try await service.critique(document: draft)
        } catch {
            print("  FAIL the critique did not complete — \(error.localizedDescription)")
            if let failure = error as? CritiqueService.Failure,
               let suggestion = failure.recoverySuggestion {
                print("       \(suggestion)")
            }
            print("\n1 of \(checks + 1) checks failed")
            exit(1)
        }

        check("the reply decoded into a report", true)
        check(
            "it read the draft's job",
            !report.jobRead.isEmpty,
            "jobRead was empty"
        )
        check(
            "it found something to say",
            !report.findings.isEmpty,
            "no findings at all, on a draft with planted problems"
        )

        // The property the whole feature rests on. A quote that cannot be
        // found is a card with no highlight, and enough of them make the
        // feature look broken while every unit test stays green.
        print("")
        print("Anchoring every quote back into the draft")
        let anchors = CritiqueAnchoring.anchor(report.findings, in: draft)
        let anchored = anchors.filter(\.isAnchored).count
        for (anchor, finding) in zip(anchors, report.findings) {
            let shortened = finding.quote.count > 48
                ? String(finding.quote.prefix(48)) + "…"
                : finding.quote
            if let range = anchor.range {
                let matched = (draft as NSString).substring(with: range)
                check(
                    "\(finding.severity.rawValue) · \(finding.category)",
                    !matched.isEmpty,
                    ""
                )
                _ = shortened
            } else {
                check(
                    "\(finding.severity.rawValue) · \(finding.category)",
                    false,
                    "could not find \"\(shortened)\" in the draft"
                )
            }
        }

        // One unanchorable quote is a model paraphrasing; most of them means
        // the prompt has stopped asking for verbatim quotes properly.
        let ratio = Double(anchored) / Double(max(1, report.findings.count))
        check(
            "most quotes are verbatim enough to highlight",
            ratio >= 0.8,
            "\(anchored) of \(report.findings.count) anchored"
        )

        print("")
        print("Report")
        print("  job read:  \(report.jobRead)")
        print("  overall:   \(report.overall)")
        print("  findings:  \(report.findings.count) (\(anchored) anchored)")
        print("  patterns:  \(report.repeatedPatterns.count)")
        print("  keep:      \(report.keep.count)")

        finish()
    }
}

/// Renders the rail for real.
///
/// Everything else here checks the model behind the rail. This checks the rail
/// itself, which otherwise has no coverage at all: a `ForEach` over a
/// non-unique id, a missing environment value, or a layout that resolves to
/// nothing are all runtime faults that compile perfectly and would first be
/// seen by whoever opened the feature.
@MainActor
func checkTheRailRenders() {
    print("")
    print("Rendering the rail")

    let model = CritiqueModel()
    let source = "Alpha paragraph.\n\nBeta paragraph with a claim in it."
    model.applyForChecking(
        CritiqueReport(
            jobRead: "A short note for developers.",
            overall: "Clear, but the claim needs support.",
            findings: [
                CritiqueFinding(
                    severity: .high, category: "Logic and credibility",
                    needsVerification: true, location: "paragraph 2",
                    quote: "a claim in it", why: "Nothing supports it.",
                    direction: "Cite a source."
                ),
                CritiqueFinding(
                    severity: .low, category: "Voice and tone",
                    location: "paragraph 1",
                    quote: "Alpha paragraph.", why: "Generic opening.",
                    fix: "Name the subject."
                ),
                // One the model paraphrased, so it cannot be anchored. The rail
                // has to render it too, saying so, rather than dropping it.
                CritiqueFinding(
                    severity: .medium, category: "Structure and pacing",
                    location: "whole draft",
                    quote: "words that are not in the draft",
                    why: "No running example."
                ),
            ],
            repeatedPatterns: [
                CritiquePattern(pattern: "Unsupported claims", locations: ["paragraph 2"])
            ],
            keep: ["The piece is short."]
        ),
        for: source
    )

    let rail = CritiqueSidebar(
        critique: model,
        colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: true,
        onRerun: {}
    )
    let host = NSHostingView(rootView: rail)
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless],
        backing: .buffered, defer: false
    )
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()

    let size = host.fittingSize
    check(
        "the rail lays out to a real size",
        size.width > 0 && size.height > 0,
        "fitting size was \(size)"
    )

    // Read the text back out of the view tree, which is the only way to know
    // the cards actually rendered rather than merely being asked to.
    var shown: [String] = []
    func collect(_ view: NSView) {
        if let text = view as? NSTextField { shown.append(text.stringValue) }
        if let value = view.accessibilityValue() as? String { shown.append(value) }
        if let label = view.accessibilityLabel() { shown.append(label) }
        view.subviews.forEach(collect)
    }
    collect(host)
    let all = shown.joined(separator: "\n")

    for expected in [
        "Nothing supports it.",
        "Generic opening.",
        "No running example.",
    ] {
        check(
            "the rail shows \"\(expected)\"",
            all.contains(expected),
            "not found among \(shown.count) labels"
        )
    }
    check(
        "an unanchored finding still gets a card, and says so",
        all.contains("Not found in the document"),
        "the unanchored card is missing or silent"
    )
    // Drawn to a bitmap rather than captured from the screen: this has to
    // work on a locked machine, where every screen capture fails.
    if let path = ProcessInfo.processInfo.environment["MDE_RAIL_PNG"],
       let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("---- labels ----")
        for label in shown where !label.isEmpty { print("  · \(label)") }
        print("----------------")
    }
    // The header and the stale notice are drawn by SwiftUI without a backing
    // `NSTextField`, so the walk above cannot see them however well they
    // render — two checks here failed while the rail was demonstrably correct.
    // They are checked from the drawn pixels instead, which is the only thing
    // that can tell "not rendered" from "not reachable from here".
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        check("the rail can be drawn", false)
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / host.bounds.width

    /// How much of a band is not the background colour.
    func inkedFraction(fromTop top: CGFloat, height: CGFloat) -> Double {
        let firstRow = Int(top * scale)
        let lastRow = min(rep.pixelsHigh, Int((top + height) * scale))
        guard firstRow < lastRow else { return 0 }
        let background = rep.colorAt(x: 4, y: firstRow)?.usingColorSpace(.sRGB)
        var inked = 0, total = 0
        for y in firstRow..<lastRow {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let background else { continue }
                total += 1
                let difference = abs(colour.redComponent - background.redComponent)
                    + abs(colour.greenComponent - background.greenComponent)
                    + abs(colour.blueComponent - background.blueComponent)
                if difference > 0.08 { inked += 1 }
            }
        }
        return total == 0 ? 0 : Double(inked) / Double(total)
    }

    /// How many pixels in a band are clearly the theme's accent colour.
    ///
    /// Keyed on the accent rather than on ink, because whatever is below the
    /// header slides up into its place when it is missing — so "something is
    /// drawn at the top" passes either way, which it did. The sparkles mark is
    /// the one accent-coloured thing up there.
    func accentPixels(fromTop top: CGFloat, height: CGFloat) -> Int {
        let firstRow = Int(top * scale)
        let lastRow = min(rep.pixelsHigh, Int((top + height) * scale))
        guard firstRow < lastRow else { return 0 }
        var found = 0
        for y in firstRow..<lastRow {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if colour.blueComponent - colour.redComponent > 0.30,
                   colour.blueComponent > 0.55 {
                    found += 1
                }
            }
        }
        return found
    }

    let accent = accentPixels(fromTop: 0, height: 34)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  accent pixels in the header band: \(accent)")
    }
    check(
        "the header is drawn, mark and all",
        accent > 40,
        "only \(accent) accent-coloured pixels at the top of the rail"
    )
    /// The widest unbroken run of non-background pixels in a band, in points.
    ///
    /// Text never gives a long run — it is letters with gaps. A filled panel
    /// does. This is what tells the stale notice apart from the summary line
    /// that moves up into its place when the notice is not there: checking for
    /// *any* ink in the band passes either way, which it did.
    func widestRun(fromTop top: CGFloat, height: CGFloat) -> CGFloat {
        let firstRow = Int(top * scale)
        let lastRow = min(rep.pixelsHigh, Int((top + height) * scale))
        guard firstRow < lastRow else { return 0 }
        let background = rep.colorAt(x: 2, y: firstRow)?.usingColorSpace(.sRGB)
        var widest = 0
        for y in firstRow..<lastRow {
            var run = 0
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let background else { continue }
                let difference = abs(colour.redComponent - background.redComponent)
                    + abs(colour.greenComponent - background.greenComponent)
                    + abs(colour.blueComponent - background.blueComponent)
                if difference > 0.03 {
                    run += 1
                    widest = max(widest, run)
                } else {
                    run = 0
                }
            }
        }
        return CGFloat(widest) / scale
    }

    let noticeRun = widestRun(fromTop: 36, height: 52)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  widest run in the notice band: \(Int(noticeRun))pt")
    }
    check(
        "a stale critique says so rather than drifting quietly",
        noticeRun > 150,
        "widest run was \(Int(noticeRun))pt, which is text, not a panel"
    )
}

@MainActor
func finish() -> Never {
    print("")
    if failures == 0 {
        print("ALL PASS (\(checks) checks)")
        exit(0)
    }
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
