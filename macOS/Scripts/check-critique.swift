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
import CoreText
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

        Caching is important because the cache stores data for later reads, \
        and a passage this long has to wrap onto several lines so the shading \
        can be measured on a line it covers completely — which is the case \
        that used to run the full width of the page.

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
            // Spans several lines, so at least one line is covered end to end.
            // A mark measured per *fragment* rather than per glyph run swells
            // to the container's width on exactly that line.
            quote: "the cache stores data for later reads, and a passage this "
                + "long has to wrap onto several lines",
            why: "Vague."
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
            .init(id: finding.id, range: rendered, colour: finding.severity.highlight(on: .light))
        )
    }
    view.critiqueHighlights = highlights

    guard let layoutManager = view.layoutManager else {
        check("the view has a layout manager", false)
        return
    }

    // The shading is drawn, not attributed. An attribute fills the whole line
    // fragment, so it ran out into the page margin and along the empty tail of
    // every short line — marking the lines a passage was on rather than the
    // passage. These boxes are what is actually painted.
    for (highlight, finding) in zip(highlights, findings) {
        let boxes = view.critiqueHighlightBoxes(for: highlight.range)
        check(
            "the \(finding.severity.rawValue) passage is shaded",
            !boxes.isEmpty,
            "nothing is drawn for it"
        )
        // The point of the change: the mark hugs the words. *Every* box, not
        // the first — the first version of this checked `boxes.first` and
        // passed while the middle line of a three-line passage ran the whole
        // width of the page, which is exactly the fault it was written for.
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: highlight.range, actualCharacterRange: nil
        )
        let inked = layoutManager.boundingRect(
            forGlyphRange: glyphs, in: view.textContainer!
        )
        let widest = boxes.map(\.width).max() ?? 0
        check(
            "and hugs the words rather than the line",
            widest <= inked.width + 12,
            "the widest mark is \(Int(widest))pt for \(Int(inked.width))pt of text"
        )
        let rightmost = boxes.map(\.maxX).max() ?? 0
        let leftmost = boxes.map(\.minX).min() ?? 0
        check(
            "so it stays out of the page margin",
            rightmost <= view.bounds.width - view.textContainerInset.width + 4
                && leftmost >= view.textContainerInset.width - 4,
            "it runs \(Int(leftmost))…\(Int(rightmost)) in a \(Int(view.bounds.width))pt view"
        )
    }

    // A range that runs over a paragraph break shades the words, not the gap.
    //
    // A newline is laid out as a glyph reaching the end of its line fragment,
    // so measuring one draws a band the full width of the column — which is
    // what appeared between every pair of paragraphs, a stack of orange bars
    // on the empty lines. Asserted directly on the drawing, because the
    // checks above compare each box against the range's own bounding rect and
    // a range ending in a newline has a full-width bounding rect too: the
    // wrong answer and the yardstick were the same number.
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  rendered: " + view.string
            .replacingOccurrences(of: "\n", with: "\\n").prefix(220))
    }
    // Anchored on the paragraph break itself, so the range really does contain
    // the newlines. Aimed at the words either side of it and nothing else.
    let text = view.string as NSString
    let breakRange = text.range(of: "\n\n", options: [], range: NSRange(
        location: 24, length: max(0, text.length - 24)
    ))
    if breakRange.location != NSNotFound, breakRange.location >= 10 {
        let spanning = NSRange(
            location: breakRange.location - 10,
            length: min(10 + breakRange.length + 10, text.length - breakRange.location + 10)
        )
        let boxes = view.critiqueHighlightBoxes(for: spanning)
        let widest = boxes.map(\.width).max() ?? 0
        let container = view.textContainer?.size.width ?? view.bounds.width
        check(
            "a mark crossing a paragraph break shades no empty line",
            widest < container - 40,
            "the widest mark is \(Int(widest))pt in a \(Int(container))pt column, "
                + "so the blank line is banded"
        )
    }

    // Nothing is drawn over the heading. Written as a real comparison rather
    // than a shape that cannot fail: the first version of this ended in
    // `|| true`, which is a check that passes whatever happens.
    let headingBoxAll = layoutManager.boundingRect(
        forGlyphRange: layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 20),
            actualCharacterRange: nil
        ),
        in: view.textContainer!
    ).offsetBy(
        dx: view.textContainerInset.width, dy: view.textContainerInset.height
    )
    let marksOverHeading = highlights
        .flatMap { view.critiqueHighlightBoxes(for: $0.range) }
        .filter { $0.intersects(headingBoxAll) }
    check(
        "the heading is left alone",
        marksOverHeading.isEmpty,
        "\(marksOverHeading.count) marks overlap it"
    )

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
        // Aimed at a box that is really drawn, rather than at the centre of
        // the range's overall bounds. For a passage spanning several lines
        // that centre can fall past the end of a short line and hit nothing —
        // a failure of the aim, not of the app.
        guard let box = view.critiqueHighlightBoxes(for: highlight.range).first
        else {
            check("\(finding.severity.rawValue) passage is drawn to click on", false)
            continue
        }
        let point = CGPoint(x: box.midX, y: box.midY)
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

/// Load the fonts the app bundles, so this measures what the app draws.
@MainActor
func registerBundledFonts() {
    let directory = URL(fileURLWithPath: "Packaging/Fonts")
    let files = (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )) ?? []
    for file in files where file.pathExtension.lowercased() == "ttf" {
        CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
    }
}

/// Every hand the picker offers can actually be drawn with, and the optical
/// scales really do bring them to the same read size.
///
/// The first half is not busywork: the faces are referenced by PostScript
/// name and shipped as files, so a rename or a missing file degrades silently
/// into a fallback that still looks like handwriting. Nothing else here would
/// notice.
@MainActor
func checkTheHandsAreAvailable() {
    print("")
    print("The hands on offer")

    var readSizes: [(String, CGFloat)] = []
    for hand in CritiqueHand.allCases {
        let font = NSFont(name: hand.fontName, size: 100 * hand.opticalScale)
        check(
            "\(hand.title) is bundled and loads",
            font != nil,
            "\(hand.fontName) did not resolve — the rail would quietly fall "
                + "back to another face"
        )
        if let font { readSizes.append((hand.title, font.xHeight)) }
    }

    // The picker's wiring: choosing a hand has to reach the type helper every
    // label on the rail goes through. Without this the menu can look like it
    // works — the tick moves — while the rail keeps drawing in the old face.
    let chosen = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    for hand in CritiqueHand.allCases {
        UserDefaults.standard.set(hand.rawValue, forKey: CritiqueHand.storageKey)
        check(
            "choosing \(hand.title) is what the rail then writes in",
            CritiqueTypography.familyChain.first == hand.fontName,
            "the chain still starts with "
                + "\(CritiqueTypography.familyChain.first ?? "nothing")"
        )
    }
    if let chosen {
        UserDefaults.standard.set(chosen, forKey: CritiqueHand.storageKey)
    } else {
        UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
    }

    guard readSizes.count == CritiqueHand.allCases.count,
          let low = readSizes.min(by: { $0.1 < $1.1 }),
          let high = readSizes.max(by: { $0.1 < $1.1 })
    else { return }
    // Asking for the same size should give the same *read* size, whichever
    // hand is chosen, or switching font silently resizes the whole rail.
    let drift = (high.1 - low.1) / low.1
    check(
        "and all three read at the same size",
        drift < 0.10,
        String(
            format: "%@ is %.0f%% larger than %@ at the same requested size",
            high.0, drift * 100, low.0
        )
    )
}

@main
@MainActor
struct CheckCritique {
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // The app loads these through `ATSApplicationFontsPath`, which only
        // applies to a bundle. This is a bare executable, so without doing it
        // by hand the rail renders in whatever the chain falls through to —
        // and it did: Architects Daughter and Caveat were unavailable here
        // while Permanent Marker happened to be registered by the installed
        // app, so every measurement of "the score" was a measurement of a font
        // that is not the one shipping.
        registerBundledFonts()

        checkTheHandsAreAvailable()
        checkTheDocumentFillsTheWindow()
        checkTheFormattingBarIsACentredRow()
        checkThePointerOverTheBarIsAnArrow()
        checkTheHeaderIsItsOwnSurface()
        checkMarksFollowTheWords()
        checkTheScoreIsLegible()
        checkEveryColourIsLegible()
        checkHighlightsAndClicking()
        checkTheHistory()
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
        var stagesSeen: [CritiqueProgress.Stage] = []
        var sawCommentary = false
        var peakFindings = 0
        do {
            report = try await service.critique(document: draft) { update in
                if stagesSeen.last != update.stage {
                    stagesSeen.append(update.stage)
                    print("    · \(update.stage.headline)")
                }
                if update.stage == .reading, update.detail != nil { sawCommentary = true }
                peakFindings = max(peakFindings, update.findingsSoFar)
            }
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

        // The whole point of streaming: the wait has to be legible. A run that
        // only ever reported one stage is a spinner with extra steps.
        check(
            "the run reported more than one stage",
            stagesSeen.count >= 2,
            "saw \(stagesSeen.map(\.headline).joined(separator: ", "))"
        )
        check(
            "it reached the writing stage",
            stagesSeen.contains(.writing),
            "never announced writing the report"
        )
        check(
            "it showed the model's own account of what it was reading",
            sawCommentary,
            "no commentary during the reading stage"
        )
        check(
            "notes were counted as they streamed in",
            peakFindings > 0,
            "the count never moved off zero"
        )
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
            whatWorks: ["The mechanism is described correctly."],
            whatDoesNotWork: ["Nothing is grounded in an example."],
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

    // Answer one, so the check covers the score moving, the answered section,
    // and a resolved passage giving up its shading.
    let outstandingBefore = model.outstanding.count
    let scoreBefore = model.score
    let answered = model.items.first { $0.finding.severity == .low }
    model.setResolution(.dismissed, for: answered!.id)

    check(
        "answering one takes it out of the outstanding count",
        model.outstanding.count == outstandingBefore - 1,
        "\(model.outstanding.count) of \(outstandingBefore)"
    )
    check(
        "the score goes up when something is answered",
        model.score > scoreBefore,
        "\(scoreBefore) -> \(model.score)"
    )
    check(
        "an answered finding stops shading its passage",
        !model.highlights.contains { $0.id == answered!.id },
        "it is still shaded"
    )
    check(
        "and moves to the bottom of the list",
        model.items.last?.id == answered!.id,
        "it is at position \(model.items.firstIndex { $0.id == answered!.id } ?? -1)"
    )
    check(
        "answering everything returns the score to a hundred",
        {
            let all = CritiqueModel()
            all.applyForChecking(
                CritiqueReport(jobRead: "", overall: "", findings: model.items.map(\.finding)),
                for: source
            )
            for item in all.items { all.setResolution(.completed, for: item.id) }
            return all.score == 100
        }(),
        "it did not reach 100"
    )
    // And taking the answer back restores it.
    model.setResolution(nil, for: answered!.id)
    check(
        "undoing an answer brings the finding back",
        model.outstanding.count == outstandingBefore
            && model.score == scoreBefore,
        "\(model.outstanding.count) outstanding, score \(model.score)"
    )
    model.setResolution(.dismissed, for: answered!.id)

    let rail = CritiqueSidebar(
        critique: model,
        colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: true,
        onRerun: {}
    )
    let host = NSHostingView(rootView: rail)
    // Tall enough for the whole pad. At 900 the second note fell off the
    // bottom the moment the type grew, and the check that compares the papers
    // could only see one of them — which reads as "the severities share a
    // colour" when the truth is "the note is not on screen".
    host.frame = NSRect(x: 0, y: 0, width: 340, height: 1500)
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
        // The summary note carries both halves of the read, not just one
        // sentence about the piece.
        "The mechanism is described correctly.",
        "Nothing is grounded in an example.",
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
    /// Returned in *points squared*, not pixels.
    ///
    /// A backing store is 1x or 2x depending on what the window ended up on,
    /// and a threshold in raw pixels quietly means four times as much on one
    /// as on the other — measured here as 77 against 18 for the same rail,
    /// which failed the check by changing nothing but the order of the checks.
    func accentPixels(fromTop top: CGFloat, height: CGFloat) -> Double {
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
        // Sampled every second column, so each hit stands for two pixels.
        return Double(found) * 2 / Double(scale * scale)
    }

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

    /// How much of a band is a strongly coloured pixel, in points squared.
    ///
    /// The score is drawn as a big numeral in the severity tint. Everything
    /// else that could occupy that band — the stale notice, the summary — is
    /// grey on grey, so saturation is what tells them apart. Looking for a
    /// filled panel does not: the stale notice is one too, and slides up into
    /// this band the moment the score is removed. That version of this check
    /// passed against a build with the score deleted.
    func saturatedArea(fromTop top: CGFloat, height: CGFloat) -> Double {
        let firstRow = Int(top * scale)
        let lastRow = min(rep.pixelsHigh, Int((top + height) * scale))
        guard firstRow < lastRow else { return 0 }
        var found = 0
        for y in firstRow..<lastRow {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let high = max(c.redComponent, max(c.greenComponent, c.blueComponent))
                let low = min(c.redComponent, min(c.greenComponent, c.blueComponent))
                if high - low > 0.25 { found += 1 }
            }
        }
        return Double(found) * 2 / Double(scale * scale)
    }

    /// The contrast ratio between the score numeral and the wash behind it,
    /// measured from the drawn pixels.
    ///
    /// The numeral is *found*, not assumed to be at an offset. A fixed band was
    /// the first version and it has been wrong twice: once when the type scale
    /// grew and once when the face changed, both times reporting a confident
    /// number about a strip of empty paper below the number it meant to
    /// measure. 1.10:1 is what "I am looking at the wrong pixels" reads like.
    ///
    /// Found by saturation rather than by darkness, because the ink is dark on
    /// a light theme and light on a dark one, but it is strongly coloured in
    /// both — and the paper, the canvas and the grid never are. The border and
    /// the progress bar are also saturated, so the numeral is taken as the
    /// tallest unbroken block of such rows: a border is two pixels and the bar
    /// is seven points, against the numeral's thirty-odd.
    func scoreContrast() -> Double {
        func luminance(_ c: NSColor) -> Double {
            func channel(_ raw: CGFloat) -> Double {
                let v = Double(raw)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent)
                + 0.7152 * channel(c.greenComponent)
                + 0.0722 * channel(c.blueComponent)
        }
        func spread(_ c: NSColor) -> CGFloat {
            max(c.redComponent, max(c.greenComponent, c.blueComponent))
                - min(c.redComponent, min(c.greenComponent, c.blueComponent))
        }

        // The verdict on the right is grey on the same wash and is a different
        // question, so only the left of the banner is considered.
        let lastCol = min(rep.pixelsWide, Int(Double(rep.pixelsWide) * 0.42))
        let firstCol = Int(18 * scale)
        let searchTo = min(rep.pixelsHigh, Int(280 * scale))
        guard firstCol < lastCol, searchTo > 0 else { return 0 }

        var isInkRow = [Bool](repeating: false, count: searchTo)
        for y in 0..<searchTo {
            var found = 0
            for x in firstCol..<lastCol {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                if spread(c) > 0.25 { found += 1 }
            }
            isInkRow[y] = found >= 4
        }
        var best = (start: 0, length: 0)
        var runStart = 0, run = 0
        for y in 0..<searchTo {
            if isInkRow[y] {
                if run == 0 { runStart = y }
                run += 1
                if run > best.length { best = (runStart, run) }
            } else {
                run = 0
            }
        }
        guard best.length > Int(12 * scale) else { return 0 }
        let firstRow = best.start
        let lastRow = best.start + best.length

        var counts: [String: (n: Int, colour: NSColor)] = [:]
        var luminances: [Double] = []
        for y in firstRow..<lastRow {
            for x in firstCol..<lastCol {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let key = "\(Int(c.redComponent * 32))"
                    + "-\(Int(c.greenComponent * 32))"
                    + "-\(Int(c.blueComponent * 32))"
                counts[key, default: (0, c)].n += 1
                luminances.append(luminance(c))
            }
        }
        guard let wash = counts.values.max(by: { $0.n < $1.n })?.colour,
              !luminances.isEmpty
        else { return 0 }
        let washLuminance = luminance(wash)
        luminances.sort()
        // The 5th percentile rather than the single darkest pixel, so a stray
        // antialiased corner cannot stand in for the stroke.
        let index = max(1, luminances.count / 20)
        let inkLuminance = washLuminance > 0.5
            ? luminances[index]
            : luminances[luminances.count - 1 - index]
        if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
            print(String(
                format: "    numeral rows %d-%d of %d, wash %.2f %.2f %.2f "
                    + "(L %.3f), ink L %.3f",
                firstRow, lastRow, rep.pixelsHigh, wash.redComponent,
                wash.greenComponent, wash.blueComponent, washLuminance,
                inkLuminance
            ))
        }
        let lighter = max(inkLuminance, washLuminance)
        let darker = min(inkLuminance, washLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The two colours the notes are most often painted in.
    ///
    /// The *most frequent* rather than the distinct count: every antialiased
    /// edge is its own colour, so counting buckets reports sixteen either way
    /// and passes whatever is drawn — measured at 16 against 18 for a build
    /// with all three severities forced to one paper. The dominant colours are
    /// the fills, and comparing those actually answers the question.
    func dominantPapers(
        fromTop top: CGFloat, height: CGFloat, excluding: NSColor?
    ) -> [(String, Int)] {
        let firstRow = Int(top * scale)
        let lastRow = min(rep.pixelsHigh, Int((top + height) * scale))
        var counts: [String: Int] = [:]
        guard firstRow < lastRow else { return [] }
        let skip = excluding?.usingColorSpace(.sRGB)
        for y in stride(from: firstRow, to: lastRow, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                // Pale but tinted: a note's paper, not the page and not the ink.
                guard r > 0.78, g > 0.72, b > 0.68,
                      max(r, max(g, b)) - min(r, min(g, b)) > 0.06
                else { continue }
                // The score banner is a pale tinted fill too, and it is not a
                // note. Left in, it took second place off the yellow paper the
                // moment the type scale changed and the pad moved down.
                if let skip {
                    let difference = abs(r - skip.redComponent)
                        + abs(g - skip.greenComponent)
                        + abs(b - skip.blueComponent)
                    if difference < 0.12 { continue }
                }
                // Bucketed by *hue*, not by RGB. "Coloured by severity" is a
                // statement about hue, and an RGB bucket splits one paper
                // across two bins when its rendered shade lands on a boundary
                // — which halved the yellow note's count and read as the two
                // severities sharing a colour.
                let hue = Int(c.hueComponent * 12) % 12
                counts["hue \(hue)", default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    // The whole pad, not a guessed band. A fixed window stops covering the
    // notes the moment anything above them changes height — which is exactly
    // what happened when the summary became a note of its own.
    let bannerSeverity: CritiqueSeverity = model.score >= 85
        ? .low : (model.score >= 50 ? .medium : .high)
    let theme = EditorColorTheme(color: .blue, mode: .light)
    let page = theme.editorBackgroundColor.usingColorSpace(.sRGB)!
    let bannerTint = NSColor(bannerSeverity.tint).usingColorSpace(.sRGB)!
    let bannerWash = NSColor(
        srgbRed: page.redComponent * 0.88 + bannerTint.redComponent * 0.12,
        green: page.greenComponent * 0.88 + bannerTint.greenComponent * 0.12,
        blue: page.blueComponent * 0.88 + bannerTint.blueComponent * 0.12,
        alpha: 1
    )
    let papers = dominantPapers(
        fromTop: 200, height: host.bounds.height - 200, excluding: bannerWash
    )
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  dominant note papers: \(papers.prefix(3).map { "\($0.0)x\($0.1)" })")
    }
    // A *share*, not a count. With one paper for every severity the second
    // commonest colour is still a thousand antialiased pixels, which clears
    // any fixed threshold — measured at 1.8% of the first, against 69% when
    // the notes really are two colours.
    check(
        "notes are written on paper coloured by severity",
        papers.count >= 2 && papers[1].1 * 4 > papers[0].1
            && papers[0].0 != papers[1].0,
        papers.count < 2
            ? "only one paper colour is used"
            : "the two commonest papers are \(papers[0].0) x\(papers[0].1) and "
                + "\(papers[1].0) x\(papers[1].1)"
    )

    let scoreInk = saturatedArea(fromTop: 58, height: 64)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  saturated ink in the score band: \(Int(scoreInk))pt²")
        for top in stride(from: 0.0, to: 200.0, by: 20.0) {
            print("    band \(Int(top))-\(Int(top)+20): \(Int(saturatedArea(fromTop: top, height: 20)))pt²")
        }
    }
    check(
        "the awesomeness score is drawn",
        scoreInk > 150,
        "only \(Int(scoreInk))pt² of coloured ink where the score belongs"
    )

    // The numeral occupies the upper part of the banner; the bar underneath is
    // solid tint and would be measured as if it were a letter.
    let contrast = scoreContrast()
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  score contrast: \(String(format: "%.2f", contrast)):1")
    }
    check(
        "and is legible against the wash behind it",
        contrast >= 4.5,
        "the numeral measures \(String(format: "%.2f", contrast)):1, and readable "
            + "text wants 4.5:1"
    )

    let accent = accentPixels(fromTop: 0, height: 34)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  accent mark in the header band: \(Int(accent))pt²  (scale \(scale))")
    }
    check(
        "the header is drawn, mark and all",
        accent > 15,
        "only \(Int(accent))pt² of accent colour at the top of the rail"
    )

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

/// Every colour the rail sets words in, against the colour behind them.
///
/// A pass rather than a spot check, because the failure it is here to catch is
/// systematic: the note papers were three fixed pastels while the writing on
/// them followed the theme, so in a dark theme the pad was light grey on pale
/// pink and could not be read at all. One pairing being wrong is a bug; the
/// whole family being wrong is what happens when a colour is chosen in one
/// theme and never looked at in the other.
///
/// Thresholds are the WCAG ones — 4.5:1 for text, 3:1 for text at 24pt and up.
/// The score numeral is the only large one here.
@MainActor
func checkEveryColourIsLegible() {
    print("")
    print("Reading the rail")

    func srgb(_ colour: Color) -> NSColor {
        NSColor(colour).usingColorSpace(.sRGB)!
    }
    func srgb(_ colour: NSColor) -> NSColor {
        colour.usingColorSpace(.sRGB)!
    }
    /// `ink` laid over `background` at its own alpha, as the screen composites it.
    func over(_ ink: NSColor, _ background: NSColor) -> NSColor {
        let a = ink.alphaComponent
        return NSColor(
            srgbRed: ink.redComponent * a + background.redComponent * (1 - a),
            green: ink.greenComponent * a + background.greenComponent * (1 - a),
            blue: ink.blueComponent * a + background.blueComponent * (1 - a),
            alpha: 1
        )
    }
    func luminance(_ colour: NSColor) -> Double {
        let c = srgb(colour)
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }
    func contrast(_ ink: NSColor, on background: NSColor) -> Double {
        let a = luminance(over(srgb(ink), srgb(background)))
        let b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    for mode in [EditorAppearanceMode.light, .dark] {
        let theme = EditorColorTheme(color: .blue, mode: mode)
        let primary = srgb(theme.primaryTextColor)
        let secondary = srgb(theme.secondaryTextColor)
        let card = srgb(theme.editorBackgroundColor)
        // The rail's background *is* the page now — one colour through the
        // whole window, with the column marked by a hairline instead of by a
        // second surface. This measured against `PixelStyle.canvas`, which the
        // app had stopped drawing: a legibility check against a colour nothing
        // is set on.
        let canvas = card
        // A note is not on the page, so it is not written in the page's ink.
        let noteInk = srgb(CritiqueCard.noteInk(on: mode))
        let noteSub = srgb(CritiqueCard.noteSubInk(on: mode))

        var pairs: [(String, NSColor, NSColor, Double)] = []

        for severity in [CritiqueSeverity.high, .medium, .low] {
            let paper = srgb(severity.notePaper(on: mode))
            let name = severity.rawValue
            pairs += [
                ("the category on a \(name) note", noteInk, paper, 4.5),
                ("the comment on a \(name) note", noteInk, paper, 4.5),
                ("the advice label on a \(name) note", noteSub, paper, 4.5),
                ("the location on a \(name) note", noteSub, paper, 4.5),
                ("the \(name) tag",
                 srgb(NSColor.white), srgb(severity.ink(on: .light)), 4.5),
                // An answered note is straightened onto the theme's own card,
                // and its tag turns grey-on-grey.
                // An answered note is faded to 0.62 — *the whole note*, paper and
            // writing together, against the canvas behind it. Measuring the
            // ink on the paper at full strength answers a question nobody is
            // looking at.
            ("an answered \(name) note's comment",
             over(noteInk.withAlphaComponent(0.62), canvas),
             over(card.withAlphaComponent(0.62), canvas), 4.5),
                ("the answered tag", noteInk,
                 over(noteSub.withAlphaComponent(0.18), card), 4.5),
            ]
            // The wash behind the score, and the number on it.
            let wash = over(
                srgb(severity.tint).withAlphaComponent(0.12), card
            )
            pairs += [
                ("the \(name) score", srgb(severity.ink(on: mode)), wash, 3.0),
                ("its /100", srgb(severity.ink(on: mode)), wash, 4.5),
                ("the awesomeness caption on a \(name) banner", secondary, wash, 4.5),
                ("the verdict on a \(name) banner", primary, wash, 4.5),
            ]
        }

        // The summary note, which is the theme's own card in both themes.
        pairs += [
            ("the summary's job-read line", noteSub, card, 4.5),
            ("the summary's WHAT WORKS heading",
             srgb(CritiqueCard.worksGreen(on: mode)), card, 4.5),
            ("the summary's WHAT DOESN'T WORK heading",
             srgb(CritiqueSeverity.high.ink(on: mode)), card, 4.5),
            ("the summary's body", primary, card, 4.5),
            ("an answered note's body", primary, card, 4.5),
            ("the ANSWERED divider", primary, canvas, 4.5),
            // Text that sits straight on the rail's own background.
            ("a plain rail line", noteSub, canvas, 4.5),
            ("the stale notice",
             noteSub, over(noteSub.withAlphaComponent(0.10), canvas), 4.5),
            ("the tick stamp", srgb(NSColor.white), srgb(CritiqueCard.doneGreen), 4.5),
            ("the cross stamp", srgb(NSColor.white), srgb(CritiqueCard.dismissRed), 4.5),
        ]

        // The shading in the document is a different question: not whether
        // the words on it can be read — they are the theme's own text on
        // nearly the theme's own page — but whether the mark can be *seen*.
        // A wash tuned over white can all but vanish over a dark page.
        for severity in [CritiqueSeverity.high, .medium, .low] {
            let page = srgb(theme.editorBackgroundColor)
            let shaded = over(srgb(severity.highlight(on: mode)), page)
            let visible = contrast(shaded, on: page)
            check(
                "the \(severity.rawValue) shading is visible in \(mode.rawValue)",
                visible >= 1.12,
                String(format: "%.3f:1 against the page, which is no mark at all", visible)
            )
            check(
                "and the words on it still read in \(mode.rawValue)",
                contrast(primary, on: shaded) >= 4.5,
                String(format: "%.2f:1", contrast(primary, on: shaded))
            )
        }

        for (what, ink, background, threshold) in pairs {
            let ratio = contrast(ink, on: background)
            check(
                "\(what) reads in \(mode.rawValue)",
                ratio >= threshold,
                String(format: "%.2f:1, and it wants %.1f:1", ratio, threshold)
            )
        }

      // The point of the change, asserted directly: the strip is the chosen
      // colour, so choosing a different one has to give a different strip.
      // Without this the suite only notices a fixed header when it happens to
      // collide with a page colour, which is a proxy for the claim rather than
      // the claim.
      var headers: Set<String> = []
      for colour in EditorThemeColor.allCases {
          let c = NSColor(
              PixelStyle.header(EditorColorTheme(color: colour, mode: mode))
          ).usingColorSpace(.sRGB)!
          headers.insert(
              "\(Int(c.redComponent * 255))-\(Int(c.greenComponent * 255))"
                  + "-\(Int(c.blueComponent * 255))"
          )
      }
      check(
          "the header is the colour that was chosen in \(mode.rawValue)",
          headers.count == EditorThemeColor.allCases.count,
          "\(EditorThemeColor.allCases.count) themes produce only "
              + "\(headers.count) header colours"
      )
    }
}

/// A critique's marks follow the words while the draft is edited.
///
/// The unit tests cover the arithmetic. This covers the wiring — that the
/// model is actually told, and that what it is told reaches the items — which
/// is the half that has no bearing on whether the arithmetic is right and every
/// bearing on whether anything moves.
@MainActor
func checkMarksFollowTheWords() {
    print("")
    print("Marks that follow the words")

    let original = """
        # Understanding Caching

        Caching is important because the cache stores data for later reads.
        """
    let model = CritiqueModel()
    model.attach(to: nil, text: original)
    model.applyForChecking(
        CritiqueReport(
            jobRead: "",
            overall: "",
            findings: [
                CritiqueFinding(
                    severity: .high, category: "Logic and credibility",
                    location: "paragraph 1",
                    quote: "the cache stores data", why: "Vague."
                )
            ]
        ),
        for: original
    )

    guard let anchored = model.items.first?.range else {
        check("the passage is anchored to begin with", false)
        return
    }
    let quoted = (original as NSString).substring(with: anchored)
    check(
        "the passage is anchored to begin with",
        quoted == "the cache stores data",
        "it anchored to \"\(quoted)\""
    )

    /// The words the first mark covers in a given version of the draft.
    func marked(in text: String) -> String? {
        guard let range = model.items.first?.range,
              range.location + range.length <= (text as NSString).length
        else { return nil }
        return (text as NSString).substring(with: range)
    }

    // Typing *above* the passage. Every offset below the caret moves, and a
    // mark that does not move with them slides off its sentence.
    let withHeading = original.replacingOccurrences(
        of: "# Understanding Caching",
        with: "# Understanding Caching Properly, In Detail"
    )
    model.noteCurrentText(withHeading)
    check(
        "typing above a passage does not slide its mark off",
        marked(in: withHeading) == "the cache stores data",
        "the mark now covers \"\(marked(in: withHeading) ?? "nothing")\""
    )

    // Typing immediately *after* it. This is the one the feature is for: the
    // obvious implementation grows a range by anything inserted inside it, and
    // the end of a range counts as inside.
    // Inserted so the edit lands on the mark's *last* character, with no
    // shared space in between. Written the obvious way — " in memory" — the
    // common prefix swallows the space before "for" and the edit arrives one
    // character past the end, which is a different case and passes whatever
    // the boundary rule says.
    let withMore = withHeading.replacingOccurrences(
        of: "stores data for later reads",
        with: "stores data, which is the point, for later reads"
    )
    model.noteCurrentText(withMore)
    check(
        "and typing after it does not drag the mark over the new words",
        marked(in: withMore) == "the cache stores data",
        "the mark now covers \"\(marked(in: withMore) ?? "nothing")\""
    )

    // A line break inside it. The passage stops at the break rather than
    // reaching into a paragraph that did not exist when it was written.
    let split = withMore.replacingOccurrences(
        of: "the cache stores data",
        with: "the cache\n\nstores data"
    )
    model.noteCurrentText(split)
    let after = marked(in: split) ?? ""
    check(
        "and a line break inside it ends the passage there",
        after == "the cache" && !after.contains("\n"),
        "the mark covers \"\(after.replacingOccurrences(of: "\n", with: "\\n"))\""
    )
}

/// The window's header carries a hint of the chosen colour.
///
/// A normal macOS title bar, tinted. Both claims here are easy to lose
/// silently: a tint mixed from the palette can drift to within a shade of the
/// page as the mix changes, leaving a header that says nothing about the
/// theme; and it can go the other way and swallow the title, which is drawn in
/// the theme's text colour on top of it.
@MainActor
func checkTheHeaderIsItsOwnSurface() {
    print("")
    print("The window header")

    func luminance(_ colour: NSColor) -> Double {
        let c = colour.usingColorSpace(.sRGB)!
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }

    // Every colour, not just one. The header takes the palette's own tint
    // now, so "is it a different surface from the page" and "can the title be
    // read on it" are eight different questions in each mode rather than one —
    // and the tints are not equally light. A single-theme check here would say
    // nothing about the other fifteen.
    for mode in [EditorAppearanceMode.light, .dark] {
      for colour in EditorThemeColor.allCases {
        let theme = EditorColorTheme(color: colour, mode: mode)
        let header = NSColor(PixelStyle.header(theme)).usingColorSpace(.sRGB)!
        let page = theme.editorBackgroundColor.usingColorSpace(.sRGB)!
        let dr: CGFloat = abs(header.redComponent - page.redComponent)
        let dg: CGFloat = abs(header.greenComponent - page.greenComponent)
        let db: CGFloat = abs(header.blueComponent - page.blueComponent)
        if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
            print(String(format: "  %@ header differs from the page by %.3f",
                         mode.rawValue, dr + dg + db))
        }
        check(
            "the \(colour.rawValue) header is a different surface from its page "
                + "in \(mode.rawValue)",
            dr + dg + db > 0.03,
            String(
                format: "they differ by %.3f, which is the same colour",
                dr + dg + db
            )
        )

        // And the title on it. The strip carries the window title and three
        // controls, all drawn in the theme's text colour, so a tint that is
        // close to that colour makes the header pretty and unreadable.
        let ink = theme.primaryTextColor.usingColorSpace(.sRGB)!
        let a = luminance(ink), b = luminance(header)
        let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
        check(
            "and the \(colour.rawValue) title reads on it in \(mode.rawValue)",
            contrast >= 4.5,
            String(format: "%.2f:1, and readable text wants 4.5:1", contrast)
        )

      }

      // The point of the change, asserted directly: the strip is the chosen
      // colour, so choosing a different one has to give a different strip.
      // Without this the suite only notices a fixed header when it happens to
      // collide with a page colour, which is a proxy for the claim rather than
      // the claim.
      var headers: Set<String> = []
      for colour in EditorThemeColor.allCases {
          let c = NSColor(
              PixelStyle.header(EditorColorTheme(color: colour, mode: mode))
          ).usingColorSpace(.sRGB)!
          headers.insert(
              "\(Int(c.redComponent * 255))-\(Int(c.greenComponent * 255))"
                  + "-\(Int(c.blueComponent * 255))"
          )
      }
      check(
          "the header is the colour that was chosen in \(mode.rawValue)",
          headers.count == EditorThemeColor.allCases.count,
          "\(EditorThemeColor.allCases.count) themes produce only "
              + "\(headers.count) header colours"
      )
    }
}

/// The pointer over the formatting bar is an arrow, not the editor's I-beam.
///
/// Checked as geometry and wiring rather than by moving a real mouse. What can
/// break here is the backing view being absent or laid out at zero size, at
/// which point it silently claims nothing — and the mechanism itself is the one
/// already proved for the image resize corners in `RichMarkdownTextView`.
///
/// It also records *why* the I-beam reaches the bar at all, which is the part I
/// had wrong twice: whether the text view's own surface extends underneath it.
@MainActor
func checkThePointerOverTheBarIsAnArrow() {
    print("")
    print("The pointer over the bar")

    let theme = EditorColorTheme(color: .blue, mode: .light)
    let text = Binding.constant("# Title\n\nSome writing.\n")
    let session = MarkdownEditorSession(fileURL: nil)
    let critique = CritiqueModel()
    let width = Binding.constant(CGFloat(620))
    let pane = ResizableRichTextPreview(
        text: text, documentURL: nil, session: session, colorTheme: theme,
        preferredWidth: width, minimumWidth: 320, critique: critique
    )
    let host = NSHostingView(rootView: AnyView(pane))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled], backing: .buffered,
        defer: false
    )
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()

    func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    let all = descendants(host)
    let areas = all.compactMap { $0 as? ArrowCursorArea.Area }
    let textViews = all.compactMap { $0 as? NSTextView }

    check(
        "the bar claims a cursor area",
        !areas.isEmpty,
        "no ArrowCursorArea in the pane"
    )
    guard let area = areas.first, let textView = textViews.first else { return }

    let areaFrame = area.convert(area.bounds, to: nil)
    let textFrame = textView.convert(textView.bounds, to: nil)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  cursor area \(NSStringFromRect(areaFrame))")
        print("  text view   \(NSStringFromRect(textFrame))")
        print("  overlap: \(areaFrame.intersects(textFrame))")
    }
    check(
        "and it is laid out over the controls",
        areaFrame.width > 200 && areaFrame.height > 20,
        "it is \(Int(areaFrame.width))x\(Int(areaFrame.height)), so it claims nothing"
    )
    let rects = area.cursorRects()
    check(
        "and the cursor it claims is the arrow",
        rects.count == 1 && rects[0].cursor == NSCursor.arrow
            && rects[0].rect == area.bounds,
        "it claims \(rects.count) rect(s)"
    )
    // The bar is beside the editor, not on top of it.
    //
    // Written as a real comparison after the first version of this line was
    // `intersects || !intersects` — a check that cannot fail, which is the
    // shape a check takes when it is written to record a finding rather than
    // to test one.
    //
    // The finding is worth keeping, though: the text view does *not* reach
    // under the bar, so the I-beam over the controls was never the text view's
    // rect winning a contest. Nothing claimed that region at all, and AppKit
    // left the last cursor it had been given. That is what the arrow rect is
    // for — to claim it.
    check(
        "and the editor's surface does not reach under it",
        !areaFrame.intersects(textFrame),
        "the text view covers the bar, so the arrow rect has to outrank it"
    )

}

/// The formatting bar is a centred row of icons and nothing else.
///
/// It used to be an outlined block with a fill and a hard drop, and the checks
/// here asserted exactly that — a heavy edge, square corners, the theme's own
/// fill. Those are gone, because at the top of the page the block read as a
/// slab of chrome competing with the writing. The checks went with it: an
/// assertion that a bar *has* a two point border is worse than no assertion at
/// all once the design says it must not, since it would hold the wrong thing
/// in place.
///
/// What is left is what the bar is for: the controls are centred over the
/// document, and nothing is drawn around them.
@MainActor
func checkTheFormattingBarIsACentredRow() {
    print("")
    print("The formatting bar")

    let theme = EditorColorTheme(color: .blue, mode: .light)
    let session = MarkdownEditorSession(fileURL: nil)
    let bar = FormattingBar(session: session, colorTheme: theme)

    // On an opaque backing. A hosting view leaves the area around the content
    // transparent, which reads as black once flattened — so "the first dark
    // pixel" finds the edge of the image rather than anything drawn.
    let host = NSHostingView(
        rootView: AnyView(
            bar.frame(width: 660)
                .padding(20)
                // Filling the host, not just the content. Backing only the
                // bar leaves the rest of the frame transparent, which
                // flattens to black and reads as a 700pt run of ink — a
                // frame, according to the check below, in a build that draws
                // no frame at all.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(platformColor: theme.editorBackgroundColor))
        )
    )
    host.frame = NSRect(x: 0, y: 0, width: 700, height: 90)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        check("the formatting bar can be drawn", false)
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / host.bounds.width
    if let path = ProcessInfo.processInfo.environment["MDE_BAR_PNG"] {
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }

    let page = theme.editorBackgroundColor.usingColorSpace(.sRGB)!
    func isInk(_ x: Int, _ y: Int) -> Bool {
        guard let c: NSColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return false }
        let dr: CGFloat = abs(c.redComponent - page.redComponent)
        let dg: CGFloat = abs(c.greenComponent - page.greenComponent)
        let db: CGFloat = abs(c.blueComponent - page.blueComponent)
        return dr + dg + db > 0.12
    }

    // Nothing is drawn *around* the controls. A frame gives a long unbroken
    // horizontal run; glyphs and a hairline divider never do.
    var longestRun = 0
    for y in 0..<rep.pixelsHigh {
        var run = 0
        for x in 0..<rep.pixelsWide {
            run = isInk(x, y) ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
    }
    let runWidth = CGFloat(longestRun) / scale
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  longest unbroken ink run: \(Int(runWidth))pt")
    }
    check(
        "nothing is drawn around the controls",
        runWidth < 60,
        "there is a \(Int(runWidth))pt unbroken run of ink, which is a frame"
    )

    // And the controls are centred on the document above which they sit.
    var firstGlyph: Int?
    var lastGlyph = 0
    for x in 0..<rep.pixelsWide {
        var found = false
        for y in 0..<rep.pixelsHigh where isInk(x, y) { found = true; break }
        if found {
            if firstGlyph == nil { firstGlyph = x }
            lastGlyph = x
        }
    }
    guard let firstGlyph else {
        check("the controls are drawn", false, "nothing is drawn at all")
        return
    }
    let inkMiddle = CGFloat(firstGlyph + lastGlyph) / 2 / scale
    let hostMiddle = host.bounds.width / 2
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  controls centre at \(Int(inkMiddle))pt, host centre "
            + "\(Int(hostMiddle))pt")
    }
    check(
        "and they are centred",
        abs(inkMiddle - hostMiddle) < 24,
        "they centre at \(Int(inkMiddle))pt where the bar centres at "
            + "\(Int(hostMiddle))pt"
    )

    // Big enough to aim at, measured from the drawn glyphs.
    //
    // Measured within *clusters* of ink columns rather than over the whole
    // image. The dividers between groups are 18pt tall and one point wide, so
    // "the tallest ink anywhere" is a divider whatever size the icons are —
    // that version passed against 8pt glyphs.
    var runs: [(start: Int, end: Int)] = []
    var runStart: Int?
    for x in 0..<rep.pixelsWide {
        let inked = (0..<rep.pixelsHigh).contains { isInk(x, $0) }
        if inked, runStart == nil { runStart = x }
        if !inked, let start = runStart {
            runs.append((start, x))
            runStart = nil
        }
    }
    if let start = runStart { runs.append((start, rep.pixelsWide)) }

    var tallest = 0
    for run in runs where CGFloat(run.end - run.start) / scale > 6 {
        for x in run.start..<run.end {
            var first: Int?
            var last = 0
            for y in 0..<rep.pixelsHigh where isInk(x, y) {
                if first == nil { first = y }
                last = y
            }
            if let first { tallest = max(tallest, last - first) }
        }
    }
    let glyphHeight = CGFloat(tallest) / scale
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  tallest glyph: \(Int(glyphHeight))pt")
    }
    check(
        "and big enough to aim at",
        glyphHeight >= 13,
        "the tallest glyph is \(Int(glyphHeight))pt"
    )
}

/// The document is a column that fills the window, not a sheet lying on it.
///
/// Checked from the drawn pixels, because every part of the claim is visual:
/// that the page colour reaches the top and bottom edges rather than stopping
/// short of them, that nothing casts a shadow along its bottom edge, and that
/// the first line is clear of the top rather than tucked under the toolbar.
@MainActor
func checkTheDocumentFillsTheWindow() {
    print("")
    print("The document column")

    let theme = EditorColorTheme(color: .blue, mode: .light)
    let text = Binding.constant(
        "# Understanding Caching\n\nCaching is important because the cache "
            + "stores data for later reads.\n"
    )
    let session = MarkdownEditorSession(fileURL: nil)
    let critique = CritiqueModel()
    let width = Binding.constant(CGFloat(620))
    let pane = ResizableRichTextPreview(
        text: text,
        documentURL: nil,
        session: session,
        colorTheme: theme,
        preferredWidth: width,
        minimumWidth: 320,
        critique: critique
    )

    let host = NSHostingView(rootView: AnyView(pane))
    host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        check("the document pane can be drawn", false)
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / host.bounds.width
    let page = theme.editorBackgroundColor.usingColorSpace(.sRGB)!
    if let path = ProcessInfo.processInfo.environment["MDE_PANE_PNG"] {
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }

    func isPage(_ x: Int, _ y: Int) -> Bool {
        guard let c: NSColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        else { return false }
        let dr: CGFloat = abs(c.redComponent - page.redComponent)
        let dg: CGFloat = abs(c.greenComponent - page.greenComponent)
        let db: CGFloat = abs(c.blueComponent - page.blueComponent)
        // Tight. The formatting bar's fill is the theme's sidebar tint, which
        // in a light theme is within 0.07 of the page — at a looser tolerance
        // the bar counts as document and the column appears to start at the
        // top of it.
        return dr + dg + db < 0.03
    }

    // Down the middle of the column, which is centred in the pane.
    let middle = rep.pixelsWide / 2

    // The column starts under the formatting bar rather than at the very top
    // of the pane. Found as the first row from which the page colour runs
    // unbroken to the bottom — so the bar, its drop and the gap below it are
    // all skipped without hard-coding how tall any of them are.
    var columnTop: Int?
    var run = 0
    for y in stride(from: rep.pixelsHigh - 2, through: 0, by: -1) {
        if isPage(middle, y) {
            run += 1
            if run > Int(40 * scale) { columnTop = y }
        } else {
            run = 0
        }
    }
    guard let columnTop else {
        check("the document is a column below the bar", false,
              "no unbroken run of page colour reaching the bottom")
        return
    }
    let topOffset = CGFloat(columnTop) / scale
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  column starts \(Int(topOffset))pt down")
    }
    check(
        "the document is a column below the bar",
        topOffset < 90,
        "it starts \(Int(topOffset))pt down, which is more than a bar and a gap"
    )
    check(
        "and it reaches the bottom",
        isPage(middle, rep.pixelsHigh - 2),
        "there is canvas below it"
    )

    // A stacked sheet drew its own edges and a shadow below and right of the
    // page. Both showed up as bands of not-page colour along the bottom.
    // Bounded to the column. Scanning to the edge of the *pane* counts the
    // canvas beside the document, which is 574pt² of perfectly correct desk
    // reported as a shadow.
    var columnEnd = middle
    while columnEnd + 1 < rep.pixelsWide, isPage(columnEnd + 1, rep.pixelsHigh / 2) {
        columnEnd += 1
    }
    var strays = 0
    for y in (rep.pixelsHigh - Int(14 * scale))..<rep.pixelsHigh {
        for x in stride(from: middle, to: columnEnd, by: 2)
        where !isPage(x, y) { strays += 1 }
    }
    let strayArea = Double(strays) * 2 / Double(scale * scale)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  non-page area along the bottom edge: \(Int(strayArea)) sq pt")
    }
    // One colour behind everything, and a hairline where the column ends.
    //
    // The window used to have a deeper canvas with a grid over it, so the
    // measure was obvious from the change of surface. It is all one tone now,
    // which means the *only* thing saying where the writing stops is these two
    // rules — and a faint rule is exactly the kind of thing that survives as a
    // constant while quietly not being drawn.
    var rules: [Int] = []
    for x in 0..<rep.pixelsWide {
        var run = 0
        for y in (rep.pixelsHigh / 2)..<(rep.pixelsHigh - 4) where !isPage(x, y) {
            run += 1
        }
        // A boundary is inked down its whole length; a letter is not.
        if CGFloat(run) / scale > 80 { rules.append(x) }
    }
    // Bracketing the writing, not merely present.
    //
    // Counting them is not enough: the width gripper is a full-height rule too,
    // and on its own it satisfied "there are at least two" — the check passed
    // against a build with no page boundaries at all. What matters is that one
    // is on each side of the text.
    let textLeft = Int(160 * scale)
    let textRight = rep.pixelsWide - Int(160 * scale)
    let onTheLeft = rules.contains { $0 < textLeft }
    let onTheRight = rules.contains { $0 > textRight }
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  full-height rules at \(rules.map { Int(CGFloat($0) / scale) })")
    }
    check(
        "the column's edges are marked",
        onTheLeft && onTheRight,
        "rules at \(rules.map { Int(CGFloat($0) / scale) }) do not bracket the text"
    )

    check(
        "and casts no shadow under itself",
        strayArea < 400,
        "\(Int(strayArea))pt² along the bottom edge is not the page colour"
    )

    // The gap between the chrome above and the writing.
    //
    // Measured from the bottom of the formatting bar rather than from the top
    // of the column, because the page runs behind the bar now — so "the first
    // ink below the column top" is the bar's own icons, and the check reported
    // the document's first line 12pt down in a build where the text sits 44pt
    // below the bar.
    //
    // The two are told apart by the gap between them: the bar's glyphs are one
    // band, the first line is the next, and there is clear page in between.
    var inkRows: [Int] = []
    for y in columnTop..<rep.pixelsHigh {
        for x in stride(from: Int(150 * scale), to: rep.pixelsWide - Int(150 * scale), by: 2) {
            guard let c: NSColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let r: CGFloat = c.redComponent * 0.2126
            let g: CGFloat = c.greenComponent * 0.7152
            let b: CGFloat = c.blueComponent * 0.0722
            if r + g + b < 0.45 { inkRows.append(y); break }
        }
    }
    // The bar is the first band; anything after a clear run of page is the
    // writing.
    var barBottom: Int?
    for (index, row) in inkRows.enumerated() where index + 1 < inkRows.count {
        if inkRows[index + 1] - row > Int(12 * scale) {
            barBottom = row
            break
        }
    }
    var firstInk: Int?
    rows: for y in ((barBottom ?? columnTop) + Int(4 * scale))..<rep.pixelsHigh {
        for x in stride(from: Int(150 * scale), to: rep.pixelsWide - Int(150 * scale), by: 2) {
            guard let c: NSColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let r: CGFloat = c.redComponent * 0.2126
            let g: CGFloat = c.greenComponent * 0.7152
            let b: CGFloat = c.blueComponent * 0.0722
            if r + g + b < 0.45 {
                firstInk = y
                break rows
            }
        }
    }
    let anchor = barBottom ?? columnTop
    let gap = firstInk.map { Double($0 - anchor) / Double(scale) } ?? 0
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  first line starts \(Int(gap))pt below the bar")
    }
    check(
        "and the writing starts clear of the top",
        // 55, not 30. The gap includes the bar's own bottom padding, so a
        // build with no text inset at all still measured 32 — comfortably
        // over a threshold set for a measurement that started somewhere else.
        gap >= 55,
        "the first line is \(Int(gap))pt below the formatting bar, which "
            + "reads as part of the chrome above it"
    )
}

/// The score has to be readable, and it is set on a wash of its own colour.
///
/// Checked as arithmetic because that is what it is. The severity tints are
/// chosen to look right as *fills* — a bar, a border, a tag — and a fill and a
/// label want opposite things from a colour. Set as text on 12% of itself the
/// amber measured 2.0:1 and the red 3.6:1, where readable text wants 4.5:1.
///
/// The old colours are checked as well, and are required to *fail*. Without
/// that this is a table of numbers agreeing with itself: any threshold passes
/// if nothing is ever measured against it that should not.
@MainActor
func checkTheScoreIsLegible() {
    print("")
    print("Reading the score")

    func luminance(_ colour: NSColor) -> Double {
        guard let c = colour.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.redComponent)
            + 0.7152 * channel(c.greenComponent)
            + 0.0722 * channel(c.blueComponent)
    }
    func contrast(_ ink: NSColor, on background: NSColor) -> Double {
        let a = luminance(ink), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    /// The banner's background: the tint at 12%, over the page.
    func wash(_ severity: CritiqueSeverity, _ mode: EditorAppearanceMode) -> NSColor {
        let theme = EditorColorTheme(color: .blue, mode: mode)
        let page = theme.editorBackgroundColor.usingColorSpace(.sRGB)!
        let tint = NSColor(severity.tint).usingColorSpace(.sRGB)!
        return NSColor(
            srgbRed: page.redComponent * 0.88 + tint.redComponent * 0.12,
            green: page.greenComponent * 0.88 + tint.greenComponent * 0.12,
            blue: page.blueComponent * 0.88 + tint.blueComponent * 0.12,
            alpha: 1
        )
    }

    for mode in [EditorAppearanceMode.light, .dark] {
        for severity in [CritiqueSeverity.high, .medium, .low] {
            let background = wash(severity, mode)
            let reading = contrast(NSColor(severity.ink(on: mode)), on: background)
            check(
                "the \(severity.rawValue) score reads on its own wash in \(mode.rawValue)",
                reading >= 4.5,
                String(format: "%.2f:1, and readable text wants 4.5:1", reading)
            )
            // The colour it used to be drawn in, which is the fill.
            let fill = contrast(NSColor(severity.tint), on: background)
            check(
                "and the fill colour it replaced would not have",
                fill < 4.5,
                String(
                    format: "the plain %@ tint measures %.2f:1 on its own wash, "
                        + "so this check would pass without the change",
                    severity.rawValue, fill
                )
            )
        }
    }
}


/// Looking back at an earlier critique.
///
/// The point of keeping them is not nostalgia: an old critique read against a
/// rewritten draft has to be honest about which of its notes still point at
/// something. That is only answerable because the draft it was written about
/// is kept beside it.
@MainActor
func checkTheHistory() {
    print("")
    print("Keeping earlier critiques")

    let firstDraft = "Alpha paragraph.\n\nBeta paragraph with a claim in it."
    let report = CritiqueReport(
        jobRead: "A note.", overall: "Fine.",
        findings: [
            CritiqueFinding(
                severity: .high, category: "Logic and credibility",
                location: "paragraph 2", quote: "a claim in it",
                why: "Nothing supports it."
            ),
            CritiqueFinding(
                severity: .low, category: "Voice and tone",
                location: "paragraph 1", quote: "Alpha paragraph.",
                why: "Generic opening."
            ),
        ]
    )

    var history = CritiqueHistory()
    history.add(CritiqueRevision(report: report, documentText: firstDraft))
    check("a critique is kept", history.revisions.count == 1)

    // A re-run over an unchanged draft replaces rather than stacks: two
    // critiques of the same text are two opinions about one thing, and a
    // history full of them buries the revisions that actually differ.
    history.add(CritiqueRevision(report: report, documentText: firstDraft))
    check(
        "re-running on an unchanged draft does not stack a duplicate",
        history.revisions.count == 1,
        "\(history.revisions.count) entries"
    )

    let rewritten = "Alpha paragraph.\n\nBeta paragraph, rewritten entirely."
    history.add(CritiqueRevision(report: report, documentText: rewritten))
    check("a critique of a changed draft is a new entry", history.revisions.count == 2)
    check("newest first", history.latest?.documentText == rewritten)

    // The measure that matters: how much of the old critique still applies.
    let old = history.revisions.last!
    check(
        "an old critique knows the draft has moved on",
        old.isStale(against: rewritten),
        "it thinks it is current"
    )
    check(
        "and says how many of its notes still point at something",
        old.stillApplying(to: rewritten) == 1,
        "\(old.stillApplying(to: rewritten)) of 2 — the rewritten sentence should be gone"
    )
    check(
        "all of them, against the draft it was written about",
        old.stillApplying(to: firstDraft) == 2
    )

    // Kept, but not forever: each entry carries a copy of the draft.
    var many = CritiqueHistory()
    for index in 0..<(CritiqueHistory.limit + 5) {
        many.add(
            CritiqueRevision(report: report, documentText: "draft \(index)")
        )
    }
    check(
        "the history is bounded",
        many.revisions.count == CritiqueHistory.limit,
        "\(many.revisions.count) entries"
    )
    check("and keeps the newest", many.latest?.documentText == "draft \(CritiqueHistory.limit + 4)")

    // It has to survive a relaunch, which means surviving a round trip.
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    do {
        let data = try encoder.encode(history)
        let reloaded = try decoder.decode(CritiqueHistory.self, from: data)
        check("a history survives being written and read back", reloaded == history)
    } catch {
        check("a history survives being written and read back", false, "\(error)")
    }

    // The filename is derived from the path, and has to be the same next
    // launch. Swift's own hashing is seeded per process, so a name built from
    // it would be written once and never found again.
    let once = CritiqueHistoryStore.digest("/Users/someone/Draft.md")
    let twice = CritiqueHistoryStore.digest("/Users/someone/Draft.md")
    check("the same document names the same file every time", once == twice)
    check(
        "and a different document names a different one",
        once != CritiqueHistoryStore.digest("/Users/someone/Other.md")
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
