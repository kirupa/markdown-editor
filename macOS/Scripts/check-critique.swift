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
import Vision
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
        // The system face is asked for by weight, not by name — it has no one
        // PostScript name across macOS versions, and it cannot be missing.
        let font = hand == .sans
            ? NSFont.systemFont(ofSize: 100 * hand.opticalScale)
            : NSFont(name: hand.fontName, size: 100 * hand.opticalScale)
        // A *bundled* face has to resolve: the app ships the file, so a failure
        // here means the enum and the Fonts directory have drifted apart.
        //
        // A system face is allowed to be missing — macOS makes several optional
        // downloads — which is exactly why the picker filters. Asserting it
        // resolves would fail on a machine that simply does not have it, and
        // the app is correct on that machine.
        if hand.isBundled || hand == .sans {
            check(
                "\(hand.title) resolves",
                font != nil,
                "\(hand.fontName) did not resolve — it is bundled, so either "
                    + "the file is missing from Packaging/Fonts or the "
                    + "PostScript name in CritiqueHand is wrong"
            )
        }
        if let font { readSizes.append((hand.title, font.xHeight)) }
    }

    // The enum and the shipped files have to agree, in both directions.
    //
    // Adding a case without the file gives a picker entry that silently draws
    // something else; shipping a file no case names is dead weight in the
    // bundle. Both have happened here — Monomaniac One sat in the bundle
    // uncalled for weeks.
    let fontsDir = "Packaging/Fonts"
    let shipped = Set(
        ((try? FileManager.default.contentsOfDirectory(atPath: fontsDir)) ?? [])
            .filter { $0.hasSuffix(".ttf") }
            .map { String($0.dropLast(4)) }
    )
    let named = Set(CritiqueHand.allCases.filter(\.isBundled).map(\.fontName))
    check(
        "every bundled face names a file the app actually ships",
        named.subtracting(shipped).isEmpty,
        "named but not shipped: \(named.subtracting(shipped).sorted())"
    )
    check(
        "and every shipped file is a face somebody can choose",
        shipped.subtracting(named).isEmpty,
        "shipped but unreachable: \(shipped.subtracting(named).sorted())"
    )
    // Each one carries its licence, which is the condition they are bundled
    // under. A font shipped without its OFL text is a licence violation.
    for name in named.sorted() {
        let stem = name.replacingOccurrences(of: "-Regular", with: "")
        let hasLicence = ((try? FileManager.default.contentsOfDirectory(
            atPath: fontsDir
        )) ?? []).contains { $0.hasPrefix(stem) && $0.hasSuffix(".txt") }
        check(
            "\(name) ships its licence",
            hasLicence,
            "no licence file beginning \(stem) in \(fontsDir)"
        )
    }
    // One default, not three.
    //
    // The rail's menu defaulted to Architects Daughter while Settings and the
    // drawing code both defaulted to the system face, so with nothing stored
    // the menu ticked a hand the rail was not writing in. A control lying
    // about its own state is the worst kind of wrong a picker can be, and it
    // is invisible to anyone who has ever chosen a font.
    let storedHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
    check(
        "with nothing chosen, the rail draws in the face it says it does",
        CritiqueHand.selected == CritiqueHand.initial,
        "it draws \(CritiqueHand.selected.rawValue) but both pickers start at "
            + "\(CritiqueHand.initial.rawValue)"
    )
    check(
        "and that face is one this machine can actually draw",
        CritiqueHand.initial.isAvailable,
        "\(CritiqueHand.initial.rawValue) does not resolve"
    )
    if let storedHand {
        UserDefaults.standard.set(storedHand, forKey: CritiqueHand.storageKey)
    }

    // And the agreement is structural, not a coincidence somebody has to keep
    // up. Each `@AppStorage` for this key must take its default *from*
    // `CritiqueHand.initial` rather than naming a face: the check above
    // compares the drawing code with `initial` and cannot see a literal
    // written into a view, which is exactly where the disagreement was.
    for file in [
        "Sources/MarkdownEditor/CritiqueSidebar.swift",
        "Sources/MarkdownEditor/CritiqueSettingsView.swift",
    ] {
        let source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard let at = source.range(of: "@AppStorage(CritiqueHand.storageKey)")
        else {
            check("\(file) stores the chosen hand", false, "no @AppStorage found")
            continue
        }
        let declaration = source[at.upperBound...].prefix(120)
        check(
            "\((file as NSString).lastPathComponent) takes its default from CritiqueHand.initial",
            declaration.contains("CritiqueHand.initial"),
            "it names a face directly, so it can drift from what the rail draws"
        )
    }

    check(
        "the picker offers a real choice of hands",
        CritiqueHand.available.count >= 8,
        "only \(CritiqueHand.available.count) faces are on offer"
    )
    // The filter has to actually filter — a picker that lists a face macOS has
    // not downloaded means choosing it silently draws something else.
    check(
        "and never offers one this machine cannot draw",
        CritiqueHand.available.allSatisfy { hand in
            hand == .sans || NSFont(name: hand.fontName, size: 12) != nil
        },
        "the picker is offering a face that does not resolve"
    )

    // The picker's wiring: choosing a hand has to reach the type helper every
    // label on the rail goes through. Without this the menu can look like it
    // works — the tick moves — while the rail keeps drawing in the old face.
    let chosen = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    for hand in CritiqueHand.available where hand != .sans {
        UserDefaults.standard.set(hand.rawValue, forKey: CritiqueHand.storageKey)
        check(
            "choosing \(hand.title) is what the rail then writes in",
            CritiqueTypography.familyChain.first == hand.fontName,
            "the chain still starts with "
                + "\(CritiqueTypography.familyChain.first ?? "nothing")"
        )
    }
    // The system face does not go through the chain at all, so it is checked
    // by what it draws with instead.
    UserDefaults.standard.set(
        CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey
    )
    check(
        "choosing System Sans gives the system face",
        CritiqueTypography.hand(15) == Font.system(size: 15, weight: .regular),
        "it gave something else"
    )

    // The rail speaks in two voices and they must not merge.
    //
    // A reviewer's note is somebody's judgement about your sentence. "62/100",
    // "AWESOMENESS", "WHAT WORKS", "Stop" are the app talking about that note.
    // Setting both in the same hand makes the furniture look like commentary
    // and gives a score the same weight as a criticism.
    //
    // Checked by counting the call sites rather than by looking at pixels:
    // which face a given label draws in is exactly the thing that regresses
    // one `.font(...)` at a time, and a pixel check can only see the few
    // labels that happen to be on screen in the state it rendered.
    let sidebarSource = (try? String(
        contentsOfFile: "Sources/MarkdownEditor/CritiqueSidebar.swift",
        encoding: .utf8
    )) ?? ""
    let handSites = sidebarSource.components(separatedBy: "CritiqueTypography.hand(").count - 1
    let chromeSites = sidebarSource.components(separatedBy: "CritiqueTypography.chrome(").count - 1
    check(
        "the reviewer's hand is reserved for the notes themselves",
        handSites > 0 && handSites <= 7,
        "\(handSites) places set text in the hand — a note is its category, "
            + "the reason and the advice, plus the repeated-pattern and keep "
            + "observations, and nothing else"
    )
    check(
        "and the rail's own words are set in the system face",
        chromeSites >= 25,
        "only \(chromeSites) places use the app's own voice"
    )
    // The specific labels that were handwriting and should not be. Named, so
    // that a count staying the same while the wrong lines move cannot pass.
    // The summary card is a digest of the notes, not one of them, so the whole
    // card is typeset — both bullet lists, and the audience and goal that used
    // to open it and is now the line above the rail. Half-converting it was
    // worse than not converting it: the heading said one thing in the app's
    // voice and the bullets under it answered in the reviewer's.
    for furniture in [
        "Text(\"AWESOMENESS\")", "Text(\"/100\")",
        "TextField(Self.placeholder",
        // The author's own sentence quoted back at them. It has to stay
        // recognisable as theirs, which is what the comment beside it has
        // always claimed while the code set it in the reviewer's hand.
        "Text(finding.quote)",
    ] {
        guard let at = sidebarSource.range(of: furniture) else {
            check("\(furniture) is still in the rail", false, "it was not found")
            continue
        }
        let following = sidebarSource[at.upperBound...].prefix(220)
        check(
            "\(furniture) is set in the app's voice",
            following.contains("CritiqueTypography.chrome("),
            "it is still handwritten"
        )
    }
    // The bullets of WHAT WORKS / WHAT DOESN'T WORK, found through the one
    // function that draws them.
    if let at = sidebarSource.range(of: "ForEach(Array(lines.enumerated())") {
        let following = sidebarSource[at.upperBound...].prefix(320)
        check(
            "the What Works and What Doesn't Work entries are typeset too",
            following.contains("CritiqueTypography.chrome(")
                && !following.contains("CritiqueTypography.hand("),
            "an entry in the summary card is still handwritten"
        )
    } else {
        check("the summary card's bullet list was found", false, "not found")
    }

    // The furniture must recede rather than compete: these sizes were chosen
    // against handwriting, which draws small for its point size, so handing
    // the same number to the system face makes a label louder than the note it
    // labels.
    check(
        "the app's voice is set smaller than the number asks for",
        CritiqueTypography.chromeScale < 1,
        "chromeScale is \(CritiqueTypography.chromeScale)"
    )
    check(
        "but not so much smaller that it stops being readable",
        CritiqueTypography.chromeScale >= 0.8,
        "chromeScale is \(CritiqueTypography.chromeScale), which would set the "
            + "13pt captions under 11"
    )

    // The two kinds of heading pull in opposite directions, on purpose.
    //
    // A rail heading — CRITIQUE, WHAT WORKS — has white space around it and a
    // divider under it, so weight is enough and size would only make the
    // signpost compete with the writing it points at. Inside a note there is
    // no such space, so the category has to earn its place by being plainly
    // bigger than the criticism underneath it.
    check(
        "the rail's headings are set below its body and carry bold instead",
        CritiqueTypography.headingSize < CritiqueTypography.bodySize,
        "heading \(CritiqueTypography.headingSize) against body "
            + "\(CritiqueTypography.bodySize)"
    )
    check(
        "and they really are bold",
        CritiqueTypography.heading() == CritiqueTypography.chrome(
            CritiqueTypography.headingSize, weight: .bold
        ),
        "the heading face is not bold"
    )
    check(
        "a note's heading is larger than the criticism under it",
        CritiqueTypography.noteHeadingSize > CritiqueTypography.noteBodySize,
        "\(CritiqueTypography.noteHeadingSize) against "
            + "\(CritiqueTypography.noteBodySize)"
    )
    check(
        "and its TRY/DIRECTION label sits between the two",
        CritiqueTypography.noteLabelSize > CritiqueTypography.noteBodySize
            && CritiqueTypography.noteLabelSize < CritiqueTypography.noteHeadingSize,
        "label \(CritiqueTypography.noteLabelSize)"
    )
    check(
        "the writing in a note is smaller than it was",
        CritiqueTypography.noteBodySize < CritiqueTypography.bodySize,
        "note body \(CritiqueTypography.noteBodySize) against rail body "
            + "\(CritiqueTypography.bodySize)"
    )

    // And the other way: the criticism itself must stay handwritten.
    for note in ["Text(finding.why)", "Text(finding.category)", "Text(advice)"] {
        guard let at = sidebarSource.range(of: note) else {
            check("\(note) is still in the rail", false, "it was not found")
            continue
        }
        let following = sidebarSource[at.upperBound...].prefix(160)
        check(
            "\(note) is still in the reviewer's hand",
            following.contains("CritiqueTypography.hand("),
            "the note itself lost its handwriting"
        )
    }
    check(
        "and it is the default when nothing has been chosen",
        {
            UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
            return CritiqueHand.selected == .sans
        }(),
        "the default is \(CritiqueHand.selected.title)"
    )
    if let chosen {
        UserDefaults.standard.set(chosen, forKey: CritiqueHand.storageKey)
    } else {
        UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
    }

    // A silent `return` here would be worse than a failure: this used to skip
    // itself whenever the count came up short, so a machine missing one system
    // face would quietly stop checking the sizes of all the others.
    guard let low = readSizes.min(by: { $0.1 < $1.1 }),
          let high = readSizes.max(by: { $0.1 < $1.1 })
    else {
        check("the hands can be measured at all", false, "none resolved")
        return
    }
    check(
        "every face that resolved was measured",
        readSizes.count == CritiqueHand.available.count,
        "measured \(readSizes.count) of \(CritiqueHand.available.count) available faces"
    )
    // Asking for the same size should give the same *read* size, whichever
    // hand is chosen, or switching font silently resizes the whole rail.
    let drift = (high.1 - low.1) / low.1
    check(
        "and every hand reads at the same size",
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
        checkTheHeaderIsItsOwnSurface()
        checkTheRailAsksForWhatItNeeds()
        checkPartialCritiqueKeepsTheOtherNotes()
        await checkTheKonvoSkillIsReported()
        checkMarksFollowTheWords()
        checkTheScoreIsLegible()
        checkEveryColourIsLegible()
        checkHighlightsAndClicking()
        checkTheHistory()
        checkTheRailRenders()
        await checkStopAndFailureKeepTheCritique()
        await checkNotesArriveAsTheyAreWritten()
        await checkTheCLIIsReadAsItWrites()
        await checkAQuickPass()
        await checkRerunsCarryTheNotes()
        checkApplyingASuggestion()
        await checkTheBriefIsTheReader()
        checkTheBriefLineTakesTheKeyboard()
        await checkWorkingThroughTheNotes()
        checkTheRailFitsTheNotes()
        checkTheCritiqueMenu()

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

        // What an upgrade does to somebody who was already using this.
        //
        // Critique ran through the CLI before API keys existed. If the default
        // provider is a fixed one, everybody with a working CLI setup opens the
        // new build and is told "No API key has been set" — their working thing
        // broken by a default, and nothing on screen explaining that it used to
        // work a minute ago. So with nothing chosen and a CLI present, the CLI
        // is the answer.
        //
        // The stored choice is put back afterwards: this is a real preference
        // on a real machine and the checks must not spend it.
        let storedProvider = UserDefaults.standard.string(
            forKey: CritiqueProvider.storageKey
        )
        UserDefaults.standard.removeObject(forKey: CritiqueProvider.storageKey)
        check(
            "with nothing chosen and a CLI installed, critique still uses it",
            CritiqueCredentials.provider == .copilotCLI,
            "defaulted to \(CritiqueCredentials.provider.rawValue) instead"
        )
        check(
            "and that default needs no key, so nothing asks for one",
            CritiqueCredentials.isConfigured,
            "the default provider reports itself unconfigured"
        )
        // An explicit choice still wins, or Settings would not do anything.
        CritiqueCredentials.provider = .anthropic
        check(
            "a provider chosen in Settings outranks the default",
            CritiqueCredentials.provider == .anthropic,
            "read back \(CritiqueCredentials.provider.rawValue)"
        )
        if let storedProvider {
            UserDefaults.standard.set(
                storedProvider, forKey: CritiqueProvider.storageKey
            )
        } else {
            UserDefaults.standard.removeObject(
                forKey: CritiqueProvider.storageKey
            )
        }

        print("")
        print("Running a real critique (this costs credits and takes ~30s)")
        let service = CritiqueService()
        let report: CritiqueReport
        var stagesSeen: [CritiqueProgress.Stage] = []
        var sawCommentary = false
        var peakFindings = 0
        do {
            let answer = try await service.critique(document: draft) { update in
                if stagesSeen.last != update.stage {
                    stagesSeen.append(update.stage)
                    print("    · \(update.stage.headline)")
                }
                if update.stage == .reading, update.detail != nil { sawCommentary = true }
                peakFindings = max(peakFindings, update.findingsSoFar)
            }
            report = answer.report
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

/// Stands in for the service, so a run can be held open, stopped and failed
/// without a request.
///
/// `cancel()` deliberately does nothing. That is how an API request behaved:
/// nothing stopped it, so its answer arrived after Stop. The model has to
/// ignore that answer itself rather than rely on the service to prevent it.
@MainActor
final class HeldCritique: CritiqueAsking {
    private var waiting: CheckedContinuation<CritiqueAnswer, Error>?
    private(set) var asked = 0
    /// The earlier notes the last request carried, as the critic saw them.
    private(set) var lastPrevious: [CritiquePreviousNote] = []
    /// The passage the last request was narrowed to, if it was.
    private(set) var lastFocus: String?
    /// Who the last request said the draft was for, if it said.
    private(set) var lastBrief: CritiqueBrief?
    /// Whether the last request was a full critique or a quick pass.
    private(set) var lastDepth: CritiqueDepth?
    /// The last run's progress, kept after it is answered so an update can
    /// be sent late on purpose.
    private var reporting: ((CritiqueProgress) -> Void)?
    var isWaiting: Bool { waiting != nil }

    func critique(
        document: String,
        focus: String?,
        previous: [CritiquePreviousNote],
        brief: CritiqueBrief?,
        depth: CritiqueDepth,
        onProgress: @escaping (CritiqueProgress) -> Void
    ) async throws -> CritiqueAnswer {
        asked += 1
        lastPrevious = previous
        lastFocus = focus
        lastBrief = brief
        lastDepth = depth
        reporting = onProgress
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func cancel() {}

    /// Says how the run is going, as the CLI's stream would.
    func report(_ progress: CritiqueProgress) {
        reporting?(progress)
    }

    func answer(_ report: CritiqueReport, verdicts: [String: CritiqueNoteVerdict] = [:]) {
        waiting?.resume(returning: CritiqueAnswer(report: report, verdicts: verdicts))
        waiting = nil
    }

    func refuse(_ failure: CritiqueService.Failure) {
        waiting?.resume(throwing: failure)
        waiting = nil
    }
}

/// Lets the run's task get as far as it can, so what is checked next is
/// where it settled rather than where it happened to be.
@MainActor
func settle(until condition: () -> Bool = { false }) async {
    for _ in 0..<50 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

/// Notes on the rail as the critic writes them.
///
/// What it replaced, measured on a 52-second critique of a 467-word post:
/// the first note was finished 37.6 seconds in, and the rail showed a stage
/// bar and nothing else until 52.5. A re-run was worse — it took every note
/// off the rail for the whole of it, which is the half minute somebody would
/// most like to spend working through them. A held service stands in for the
/// critic here, so the notes can be handed over one at a time.
@MainActor
func checkNotesArriveAsTheyAreWritten() async {
    print("")
    print("Notes that arrive as they are written")

    let held = HeldCritique()
    let model = CritiqueModel(service: held)
    let rail = CritiqueSidebar(
        critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: false, onRerun: {}, onRerunChanges: {}
    )
    let draft = """
        # Shipping Faster

        Our deploys take forty minutes because every test runs on every change.

        Most teams never measure where that time goes, so they guess.

        Caching the dependency install alone saved us twelve minutes a build.
        """
    let early = CritiqueFinding(
        severity: .high, category: "Logic and credibility", location: "paragraph 1",
        quote: "every test runs on every change", why: "Every test? Say which."
    )
    let late = CritiqueFinding(
        severity: .medium, category: "Clarity and precision", location: "paragraph 2",
        quote: "so they guess", why: "Who guesses, and at what?"
    )
    func words(_ id: UUID, in text: String) -> String? {
        guard let range = model.item(withID: id)?.range,
              NSMaxRange(range) <= (text as NSString).length
        else { return nil }
        return (text as NSString).substring(with: range)
    }
    // The sans hand, because a check that reads the rail back has to be
    // able to read it; the handwritten faces are for people.
    func drawnRail(_ name: String) -> String {
        let storedHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
        UserDefaults.standard.set(CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey)
        defer {
            if let storedHand {
                UserDefaults.standard.set(storedHand, forKey: CritiqueHand.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
            }
        }
        let host = NSHostingView(rootView: rail)
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 1400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if let path = ProcessInfo.processInfo.environment["MDE_ARRIVING_PNG"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: file))
            print("  wrote \(file)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }

    model.run(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "a first run with nothing written yet keeps the whole panel",
        rail.state == .running && model.items.isEmpty && model.arriving.isEmpty,
        "state \(rail.state), \(model.arriving.count) arriving"
    )

    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 1, findings: [late]))
    await settle { !model.arriving.isEmpty }
    check(
        "a note is on the rail as soon as it is written",
        model.arriving.map(\.id) == [late.id] && model.isRunning,
        "\(model.arriving.count) arriving, running \(model.isRunning)"
    )
    check(
        "anchored and shaded, so its passage can be found",
        words(late.id, in: draft) == "so they guess"
            && model.highlights.contains { $0.id == late.id },
        "marks \"\(words(late.id, in: draft) ?? "nothing")\""
    )
    if let arrived = model.arriving.first { model.press(arrived) }
    check(
        "and pressed, which opens it",
        model.selectedFindingID == late.id,
        "selected \(String(describing: model.selectedFindingID))"
    )

    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 2, findings: [late, early]))
    await settle { model.arriving.count == 2 }
    check(
        "a later note about an earlier passage goes above it, where it will land",
        model.arriving.map(\.id) == [early.id, late.id],
        "order \(model.arriving.map(\.finding.quote))"
    )
    let first = drawnRail("first-run")
    check(
        "the rail draws the notes under the run's progress",
        legible("Every test? Say which.", in: first)
            && legible("Who guesses, and at what?", in: first)
            && legible("Writing the notes", in: first)
            && legible("2 new so far", in: first),
        "read \"\(first.prefix(240))\""
    )
    // Answering half a report has nowhere to keep the answer if the run is
    // stopped, so an early note is not answerable until the run lands.
    model.setResolution(.dismissed, for: early.id)
    check(
        "an early note cannot be answered yet",
        model.item(withID: early.id)?.resolution == nil,
        "it is \(String(describing: model.item(withID: early.id)?.resolution))"
    )

    // The finished reply is decoded again, which gives every finding a new
    // identity — and every card would be replaced by a copy of itself.
    held.answer(CritiqueReport(
        jobRead: "A post for developers.", overall: "Close.",
        findings: [early.identified(as: UUID()), late.identified(as: UUID())]
    ))
    await settle { !model.isRunning }
    check(
        "the notes that arrived are the notes that land, not copies of them",
        model.items.map(\.id) == [early.id, late.id] && model.arriving.isEmpty,
        "landed \(model.items.map(\.id)), \(model.arriving.count) still arriving"
    )
    check(
        "and the one open when the run finished is still open",
        model.selectedFindingID == late.id,
        "selected \(String(describing: model.selectedFindingID))"
    )
    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 2, findings: [late, early]))
    await settle()
    check(
        "an update queued behind the answer does not put the notes back",
        model.arriving.isEmpty && model.items.count == 2 && model.progress == nil,
        "\(model.arriving.count) arriving, progress \(String(describing: model.progress))"
    )

    model.setResolution(.completed, for: early.id)
    model.run(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "a re-run leaves the notes on the rail while it reads",
        rail.state == .running && model.items.count == 2,
        "state \(rail.state), \(model.items.count) notes"
    )
    let reread = drawnRail("rerun")
    check(
        "and draws them",
        legible("Who guesses, and at what?", in: reread)
            && legible("Starting up", in: reread),
        "read \"\(reread.prefix(240))\""
    )
    let said = CritiqueFinding(
        severity: .medium, category: "Clarity and precision", location: "paragraph 2",
        quote: "so they guess", why: "Unclear who is guessing."
    )
    let new = CritiqueFinding(
        severity: .low, category: "Evidence", location: "paragraph 3",
        quote: "saved us twelve minutes a build", why: "Out of how many?"
    )
    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 2, findings: [said, new]))
    await settle { !model.arriving.isEmpty }
    check(
        "a new note joins them",
        model.arriving.map(\.id) == [new.id],
        "arriving \(model.arriving.map(\.finding.quote))"
    )
    check(
        "and one the rail already holds is not said twice",
        !model.arriving.contains { $0.id == said.id },
        "the repeat is on the rail"
    )
    let joined = drawnRail("rerun-new")
    check(
        "under a heading that says it is new",
        legible("new", in: joined) && legible("Out of how many?", in: joined)
            && legible("Who guesses, and at what?", in: joined),
        "read \"\(joined.prefix(240))\""
    )
    // The author keeps writing while the critic does.
    let typed = "Updated. " + draft
    model.noteCurrentText(typed)
    check(
        "an early note follows the text it is about",
        words(new.id, in: typed) == "saved us twelve minutes a build",
        "marks \"\(words(new.id, in: typed) ?? "nothing")\""
    )
    model.noteCurrentText(draft)

    if let arrived = model.arriving.first { model.press(arrived) }
    model.cancel()
    check(
        "Stop takes the early notes away with the run",
        !model.isRunning && model.arriving.isEmpty && model.items.count == 2,
        "running \(model.isRunning), \(model.arriving.count) arriving, "
            + "\(model.items.count) notes"
    )
    check(
        "and closes one that was open",
        model.selectedFindingID == nil && !model.highlights.contains { $0.id == new.id },
        "selected \(String(describing: model.selectedFindingID))"
    )
    check(
        "the notes from before the run keep their answers",
        model.item(withID: early.id)?.resolution == .completed,
        "it is \(String(describing: model.item(withID: early.id)?.resolution))"
    )
    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 3, findings: [said, new, early]))
    held.answer(CritiqueReport(jobRead: "Late.", overall: "", findings: [new]))
    await settle()
    check(
        "and what the stopped run says afterwards lands nowhere",
        model.arriving.isEmpty && model.items.count == 2
            && model.report?.jobRead == "A post for developers.",
        "\(model.arriving.count) arriving, \(model.items.count) notes"
    )

    model.run(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 1, findings: [new]))
    await settle { !model.arriving.isEmpty }
    held.refuse(.providerUnreachable("The request timed out."))
    await settle { !model.isRunning }
    check(
        "a run that fails takes its early notes with it",
        model.failure != nil && model.arriving.isEmpty && model.items.count == 2,
        "failure \(String(describing: model.failure)), \(model.arriving.count) arriving"
    )
    model.clearFailure()
}

/// The service reading a CLI that writes the way the real one does.
///
/// A script stands in for the CLI, first on the PATH, so the reading can be
/// checked offline: the notes have to come out as they are written, the
/// answer has to come back when the CLI says it is done rather than when it
/// gets round to exiting — measured, most of a second later — and Stop has to
/// stop the run it was pressed on, even when another has started since.
@MainActor
func checkTheCLIIsReadAsItWrites() async {
    print("")
    print("Reading the CLI as it writes")

    let files = FileManager.default
    let folder = files.temporaryDirectory
        .appendingPathComponent("konvo-cli-\(UUID().uuidString)")
    try? files.createDirectory(at: folder, withIntermediateDirectories: true)
    let cli = folder.appendingPathComponent("copilot")
    let plan = folder.appendingPathComponent("plan")
    let arguments = folder.appendingPathComponent("arguments")
    // `exec`, so Stop's signal reaches the process holding the pipe open.
    // A child `sleep` outlives a terminated shell and keeps the output open
    // until it finishes, which a real CLI does not do.
    let script = """
        #!/bin/bash
        here="$(dirname "$0")"
        printf '%s\\n' "$@" > "$here/arguments"
        while IFS= read -r line; do
          case "$line" in
            PAUSE) sleep 0.3 ;;
            HOLD) exec sleep 30 ;;
            LINGER) exec sleep 4 ;;
            REFUSE) echo "You are not signed in." >&2; exit 1 ;;
            *) printf '%s\\n' "$line" ;;
          esac
        done < "$here/plan"
        """
    try? script.write(to: cli, atomically: true, encoding: .utf8)
    try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

    func event(_ type: String, _ data: [String: Any] = [:]) -> String {
        let object: [String: Any] = ["type": type, "data": data]
        let json = try? JSONSerialization.data(withJSONObject: object)
        return json.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func writing(_ text: String) -> String {
        event("assistant.message_delta", ["deltaContent": text])
    }
    func write(_ steps: [String]) {
        try? steps.joined(separator: "\n").appending("\n")
            .write(to: plan, atomically: true, encoding: .utf8)
    }
    let one = #"{"severity":"high","category":"Logic","location":"paragraph 1","#
        + #""quote":"every test runs on every change","why":"Every test? Say which."}"#
    let two = #"{"severity":"low","category":"Evidence","location":"paragraph 3","#
        + #""quote":"saved us twelve minutes a build","why":"Out of how many?"}"#
    let opening = [
        event("assistant.reasoning_delta", ["deltaContent": "Reading the opening. "]),
        event("assistant.message_start"),
        writing(#"{"jobRead":"A post.","overall":"Close.","findings":["# + one),
    ]
    let draft = String(
        repeating: "Our deploys take forty minutes because every test runs on every change. ",
        count: 4
    )

    let storedPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let storedProvider = UserDefaults.standard.string(forKey: CritiqueProvider.storageKey)
    setenv("PATH", folder.path + ":" + storedPath, 1)
    CritiqueCredentials.provider = .copilotCLI
    defer {
        setenv("PATH", storedPath, 1)
        if let storedProvider {
            UserDefaults.standard.set(storedProvider, forKey: CritiqueProvider.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CritiqueProvider.storageKey)
        }
        try? files.removeItem(at: folder)
    }
    guard CritiqueService.locateCLI()?.path == cli.path else {
        check("the stand-in CLI is the one found", false, "found \(String(describing: CritiqueService.locateCLI()))")
        return
    }

    func wait(_ seconds: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    final class Seen { var counts: [Int] = [] }
    func start(_ service: CritiqueService, _ seen: Seen) -> Task<Result<CritiqueAnswer, Error>, Never> {
        Task { @MainActor in
            do {
                return .success(try await service.critique(document: draft) { update in
                    seen.counts.append(update.findings.count)
                })
            } catch {
                return .failure(error)
            }
        }
    }

    write(opening + [
        "PAUSE", writing("," + two), "PAUSE", writing(#"],"keep":[]}"#),
        #"{"type":"result","exitCode":0,"usage":{}}"#, "LINGER",
    ])
    let service = CritiqueService()
    let seen = Seen()
    let began = Date()
    let answered = await start(service, seen).value
    let took = Date().timeIntervalSince(began)
    let report = try? answered.get().report
    check(
        "the stand-in's answer is read",
        report?.findings.map(\.why) == ["Every test? Say which.", "Out of how many?"],
        "\(answered)"
    )
    check(
        "each note is handed over as it is finished, before the answer",
        seen.counts.contains(1) && seen.counts.last == 2,
        "the notes arrived as \(seen.counts)"
    )
    check(
        "the answer comes back when the CLI says it is done, not when it exits",
        took < 3,
        String(format: "took %.1fs against a CLI that exits 4s after its answer", took)
    )
    let passed = (try? String(contentsOf: arguments, encoding: .utf8))?
        .split(separator: "\n").map(String.init) ?? []
    let fenced = passed.firstIndex(of: "--available-tools").map { index in
        index + 1 < passed.count && passed[index + 1] == "konvo_no_tools"
    } ?? false
    check(
        "it asks for a model with no tools at all",
        fenced,
        "the arguments were \(passed.filter { $0.hasPrefix("--") })"
    )
    check(
        "a full critique leaves the model to think as hard as it would",
        !passed.contains("--reasoning-effort"),
        "the arguments were \(passed.filter { $0.hasPrefix("--") })"
    )

    // Most of what makes a quick pass quick is this flag, and nothing on
    // the rail shows whether it was sent: a pass that lost it would still
    // say QUICK PASS, and take as long as the full critique.
    write(opening + [writing(#"],"keep":[]}"#), #"{"type":"result","exitCode":0,"usage":{}}"#])
    let quickly = await Task { @MainActor in
        try? await CritiqueService().critique(document: draft, depth: .quick)
    }.value
    let quickArguments = (try? String(contentsOf: arguments, encoding: .utf8))?
        .split(separator: "\n").map(String.init) ?? []
    let effort = quickArguments.firstIndex(of: "--reasoning-effort").flatMap { index in
        index + 1 < quickArguments.count ? quickArguments[index + 1] : nil
    }
    check(
        "a quick pass tells the model to think less",
        quickly != nil && effort == CritiqueService.quickPassEffort,
        "effort \(effort ?? "not sent"), answered \(quickly != nil)"
    )

    write(opening + [#"{"type":"result","exitCode":1,"usage":{}}"#, "REFUSE"])
    let refused = await start(CritiqueService(), Seen()).value
    var failure: CritiqueService.Failure?
    if case .failure(let error) = refused { failure = error as? CritiqueService.Failure }
    check(
        "a CLI that ends its turn in failure is reported, in its own words",
        failure == .cliFailed(status: 1, message: "You are not signed in."),
        "it said \(String(describing: failure))"
    )

    write(opening + ["HOLD"])
    let stopping = CritiqueService()
    let held = Seen()
    let stopped = start(stopping, held)
    await wait { held.counts.contains(1) }
    let pressed = Date()
    stopping.cancel()
    var outcome: CritiqueService.Failure?
    if case .failure(let error) = await stopped.value {
        outcome = error as? CritiqueService.Failure
    }
    check(
        "Stop ends a run that is part-way through its notes",
        outcome == .cancelled && Date().timeIntervalSince(pressed) < 3,
        "it ended with \(String(describing: outcome))"
    )

    // Stop, and a new run before the old one has wound down. The old run
    // used to clear the new one's process as it finished, and the second
    // Stop then had nothing to stop: the run went on for as long as the
    // critic took.
    let racing = CritiqueService()
    let firstSeen = Seen()
    let firstRun = start(racing, firstSeen)
    await wait { firstSeen.counts.contains(1) }
    racing.cancel()
    let secondSeen = Seen()
    let secondRun = start(racing, secondSeen)
    await wait { secondSeen.counts.contains(1) }
    _ = await firstRun.value
    let pressedAgain = Date()
    racing.cancel()
    var second: CritiqueService.Failure?
    if case .failure(let error) = await secondRun.value {
        second = error as? CritiqueService.Failure
    }
    check(
        "Stop still stops a run started while the last one was winding down",
        second == .cancelled && Date().timeIntervalSince(pressedAgain) < 3,
        String(
            format: "it ended with %@ after %.1fs",
            String(describing: second), Date().timeIntervalSince(pressedAgain)
        )
    )
}

/// A quick pass: what a reader would trip over, and nothing else.
///
/// The full critique is the slow half of the loop — 52 seconds on a 467-word
/// post, with nothing to read for the first 38 — and most of the times
/// somebody runs it they want to know whether the rewrite they just made is
/// clean, not to be marked again. A quick pass reads the whole draft for
/// typos and serious problems only and does not score it, because it did not
/// read the draft for what the score measures.
@MainActor
func checkAQuickPass() async {
    print("")
    print("A quick pass")

    let held = HeldCritique()
    let model = CritiqueModel(service: held)
    let storedHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    UserDefaults.standard.set(CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey)
    defer {
        if let storedHand {
            UserDefaults.standard.set(storedHand, forKey: CritiqueHand.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
        }
    }
    /// The rail as drawn, read back from its pixels, in the sans hand
    /// because the handwritten faces are for people.
    func drawnRail(_ name: String, isStale: Bool = false) -> String {
        let host = NSHostingView(rootView: CritiqueSidebar(
            critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isStale: isStale, onRerun: {}, onRerunChanges: {}, onQuickPass: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 1400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if let path = ProcessInfo.processInfo.environment["MDE_QUICK_PNG"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: file))
            print("  wrote \(file)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }

    // The CLI, which needs no key, so the rail offers to run rather than to
    // set up whichever provider this machine happens to have chosen.
    let storedProvider = UserDefaults.standard.string(forKey: CritiqueProvider.storageKey)
    CritiqueCredentials.provider = .copilotCLI
    let untouched = drawnRail("empty")
    if let storedProvider {
        UserDefaults.standard.set(storedProvider, forKey: CritiqueProvider.storageKey)
    } else {
        UserDefaults.standard.removeObject(forKey: CritiqueProvider.storageKey)
    }
    // Not "Run critique" as well: a bordered button's bezel is not drawn
    // off screen, and its white title on white cannot be read back.
    check(
        "an empty rail offers the quick pass beside the full critique",
        legible("Quick pass", in: untouched) && legible("No score.", in: untouched),
        "read \"\(untouched.prefix(240))\""
    )

    let draft = """
        # Shipping Faster

        Our deploys take forty minutes becuase every test runs on every change.

        Most teams never measure where that time goes, so they guess.

        Caching the dependency install alone saved us twelve minutes a build.
        """
    let typo = CritiqueFinding(
        severity: .low, category: "Grammar and mechanics", location: "paragraph 1",
        quote: "becuase", why: "Misspelt.", replacement: "because"
    )

    model.request(on: draft, documentURL: nil, depth: .quick)
    await settle { held.isWaiting }
    check(
        "a quick pass is asked for as one",
        held.lastDepth == .quick && model.runningDepth == .quick,
        "asked \(String(describing: held.lastDepth)), running \(model.runningDepth)"
    )
    let reading = drawnRail("running")
    check(
        "and the rail says which critique is running",
        legible("Quick pass", in: reading),
        "read \"\(reading.prefix(200))\""
    )

    // Everything a full critique would fill in, filled in: a quick pass is
    // told not to judge the piece as a whole, and one that did anyway would
    // otherwise be filed as if it had.
    held.answer(CritiqueReport(
        jobRead: "A post for developers.", overall: "One misspelling.",
        whatWorks: ["A clear claim."], whatDoesNotWork: ["Thin evidence."],
        findings: [typo],
        repeatedPatterns: [CritiquePattern(pattern: "Vague plurals", locations: ["paragraph 2"])],
        keep: ["The opening line."]
    ))
    await settle { !model.isRunning }
    check(
        "it lands as a quick pass",
        model.isQuick && model.history.latest?.isQuick == true && model.items.count == 1,
        "quick \(model.isQuick), \(model.items.count) notes"
    )
    check(
        "keeping none of the judgements of the whole draft it was not asked for",
        model.report?.whatWorks.isEmpty == true
            && model.report?.whatDoesNotWork.isEmpty == true
            && model.report?.repeatedPatterns.isEmpty == true
            && model.report?.keep.isEmpty == true
            && model.report?.overall == "One misspelling.",
        "kept \(String(describing: model.report))"
    )
    check(
        "and never calls a draft ready",
        !model.isConfirmed,
        "it is confirmed"
    )
    let landed = drawnRail("landed")
    // Read without spaces: Vision closes the gap between the banner's
    // tracked capitals, and reads "1 TO FIX" as "1 tofix". Pinning the count
    // to the label is the stricter check anyway.
    check(
        "the rail counts what to fix instead of scoring the draft",
        landed.replacingOccurrences(of: " ", with: "").contains("1tofix")
            && legible("Quick pass", in: landed)
            && landed.contains(readable("scores the draft"))
            && !landed.contains("/100") && !landed.contains("awesomeness"),
        "read \"\(landed.prefix(320))\""
    )
    check(
        "and the history names it for what it is",
        model.history.latest.map(CritiqueRevisionLabel.measure) == "Quick pass",
        "it says \(String(describing: model.history.latest.map(CritiqueRevisionLabel.measure)))"
    )

    let asked = held.asked
    model.request(on: draft, documentURL: nil, depth: .quick)
    await settle()
    check(
        "a second quick pass of the same words is declined",
        held.asked == asked && model.showsUnchangedNotice,
        "asked \(held.asked - asked) more times"
    )

    // A full critique of the same words is not declined: the quick pass
    // did not ask most of what a full one does.
    model.request(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "a full critique after a quick pass reads the whole draft, and every note",
        held.asked == asked + 1 && held.lastDepth == .full && held.lastFocus == nil
            && held.lastPrevious.count == 1,
        "asked \(held.asked - asked), \(String(describing: held.lastDepth)), "
            + "focus \(held.lastFocus ?? "none"), \(held.lastPrevious.count) notes"
    )
    let structure = CritiqueFinding(
        severity: .medium, category: "Structure", location: "paragraph 2",
        quote: "so they guess", why: "Who guesses?"
    )
    let pacing = CritiqueFinding(
        severity: .medium, category: "Pacing", location: "paragraph 3",
        quote: "saved us twelve minutes a build", why: "Out of how many?"
    )
    held.answer(
        CritiqueReport(
            jobRead: "A post for developers.", overall: "Close.",
            whatWorks: ["A clear claim."], findings: [structure, pacing]
        ),
        verdicts: ["n1": .stillApplies(quote: nil, location: nil)]
    )
    await settle { !model.isRunning }
    check(
        "and scores it again",
        !model.isQuick && model.items.count == 3
            && model.history.revisions.filter(\.isQuick).isEmpty,
        "quick \(model.isQuick), \(model.items.count) notes, "
            + "\(model.history.revisions.count) revisions"
    )

    // The loop the quick pass is for: one note fixed, checked fast.
    guard let fixedID = model.items.first(where: { $0.finding.quote == "so they guess" })?.id else {
        check("the full critique's note is on the rail", false)
        return
    }
    model.setResolution(.completed, for: fixedID)
    model.request(on: draft, documentURL: nil, depth: .quick)
    await settle { held.isWaiting }
    check(
        "a quick pass after a full critique asks only about the notes marked done",
        held.lastDepth == .quick && held.lastPrevious.count == 1
            && held.lastPrevious.first?.quote == "so they guess",
        "it asked about \(held.lastPrevious.map(\.quote))"
    )
    held.answer(CritiqueReport(jobRead: "A post for developers.", overall: "Clean.", findings: []))
    await settle { !model.isRunning }
    check(
        "keeping every other note where it was",
        model.outstanding.map(\.finding.quote).sorted()
            == ["becuase", "saved us twelve minutes a build"]
            && model.item(withID: fixedID)?.isFixed == true,
        "outstanding \(model.outstanding.map(\.finding.quote))"
    )
    check(
        "and the full critique it followed is still in the history",
        model.history.latest?.isQuick == true
            && model.history.revisions.dropFirst().first?.isQuick == false,
        "\(model.history.revisions.map(CritiqueRevisionLabel.measure))"
    )

    // After a quick pass, the next full critique reads everything, however
    // small the change: nobody has read the unchanged paragraphs for anything
    // but typos since the last full one.
    let edited = draft.replacingOccurrences(of: "becuase", with: "because")
    model.noteCurrentText(edited)
    model.request(on: edited, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "a full critique after a quick pass is never narrowed to the changes",
        held.lastDepth == .full && held.lastFocus == nil,
        "focus \(held.lastFocus ?? "none")"
    )
    held.refuse(.cancelled)
    await settle { !model.isRunning }
}

/// What a re-run that does not finish does to the critique already there.
///
/// Each of these used to clear the rail: Stop replaced the notes with "The
/// critique was stopped.", a timeout replaced them with the timeout, and an
/// empty draft spun "Starting" before being refused. None of them changed the
/// draft, so none of them should change what the rail says about it.
@MainActor
func checkStopAndFailureKeepTheCritique() async {
    print("")
    print("Keeping the critique through Stop, a failure and a short draft")

    let held = HeldCritique()
    let model = CritiqueModel(service: held)
    let draft = String(
        repeating: "This paragraph says enough to be worth reading closely. ",
        count: 6
    )
    model.applyForChecking(
        CritiqueReport(
            jobRead: "A note.", overall: "Fine.",
            findings: [
                CritiqueFinding(
                    severity: .medium, category: "Clarity",
                    location: "paragraph 1",
                    quote: "This paragraph says enough", why: "Vague."
                )
            ]
        ),
        for: draft
    )
    let note = model.items.first!.id
    model.setResolution(.completed, for: note)
    let rail = CritiqueSidebar(
        critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: false, onRerun: {}, onRerunChanges: {}
    )

    model.run(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "a re-run waiting on its answer shows as running",
        model.isRunning && held.isWaiting,
        "running \(model.isRunning), asked \(held.asked)"
    )
    model.cancel()
    check(
        "Stop puts the critique back, not a message about stopping",
        !model.isRunning && model.failure == nil && model.items.count == 1,
        "running \(model.isRunning), failure \(String(describing: model.failure)), "
            + "\(model.items.count) notes"
    )
    held.answer(CritiqueReport(jobRead: "Late.", overall: "", findings: []))
    await settle()
    check(
        "and the answer that arrives after Stop lands nowhere",
        model.report?.jobRead == "A note." && model.items.count == 1,
        "the rail now shows \"\(model.report?.jobRead ?? "nothing")\""
    )
    check(
        "the answer given before Stop is still there",
        model.items.first?.resolution == .completed,
        "it is \(String(describing: model.items.first?.resolution))"
    )

    model.run(on: draft, documentURL: nil)
    await settle { held.isWaiting }
    held.refuse(.providerUnreachable("The request timed out."))
    await settle { !model.isRunning }
    check(
        "a re-run that fails keeps the notes and the answers",
        model.failure != nil && model.items.count == 1
            && model.items.first?.resolution == .completed,
        "failure \(String(describing: model.failure)), \(model.items.count) notes"
    )
    check(
        "and shows the failure above them rather than instead of them",
        rail.state == .findings,
        "it shows \(rail.state)"
    )
    // Drawn as well as decided: a banner the state allows but the layout
    // drops would pass the check above while the author saw nothing at all.
    let storedHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    UserDefaults.standard.set(CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey)
    let host = NSHostingView(rootView: rail)
    host.frame = NSRect(x: 0, y: 0, width: 340, height: 900)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.borderless],
        backing: .buffered, defer: false
    )
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    let drawn = readable(recognisedText(in: host).joined(separator: " "))
    if let path = ProcessInfo.processInfo.environment["MDE_FAILURE_PNG"],
       let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: path))
        print("  wrote \(path)")
    }
    window.orderOut(nil)
    if let storedHand {
        UserDefaults.standard.set(storedHand, forKey: CritiqueHand.storageKey)
    } else {
        UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
    }
    let message = model.failure?.errorDescription ?? ""
    check(
        "the rail draws the failure",
        !message.isEmpty && drawn.contains(readable(message)),
        "\"\(message)\" is not legible on the rail"
    )
    check(
        "and the notes it did not replace",
        drawn.contains(readable("The notes below are from the last critique")),
        "the banner's explanation is not legible"
    )
    model.clearFailure()
    check("the failure can be put away", model.failure == nil, "it is still there")

    let askedBefore = held.asked
    model.run(on: "Too short to read yet.", documentURL: nil)
    check(
        "a draft under thirty words is refused before anything spins",
        !model.isRunning && model.progress == nil,
        "running \(model.isRunning)"
    )
    await settle()
    check(
        "and nothing is sent",
        held.asked == askedBefore,
        "\(held.asked - askedBefore) requests made"
    )
    check(
        "it says how much there is, so the author knows how far off it is",
        model.failure == .draftTooShort(words: 5),
        "it says \(String(describing: model.failure))"
    )
    check(
        "and offers to run it, not to try again",
        model.failure?.retryTitle == "Run critique",
        "the button says \(model.failure?.retryTitle ?? "nothing")"
    )
    let empty = CritiqueModel(service: held)
    empty.run(on: "Too short.", documentURL: nil)
    check(
        "with nothing to keep, the failure takes the panel",
        CritiqueSidebar(
            critique: empty, colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isStale: false, onRerun: {}, onRerunChanges: {}
        ).state == .failed,
        "it shows something else"
    )
}

/// A re-run carries the notes on screen into the next critique.
///
/// What it replaced, measured on a 467-word post: one typo fixed, a re-run,
/// and the paragraph's other notes came back reworded under new identities, a
/// new nit landed on the sentence just fixed, the answered notes were gone and
/// the score was back where it started. Each step here is one of those, run
/// through the same `request`, `carryPlan` and `land` the window uses, with a
/// held service standing in for the critic so its answer can be dictated.
@MainActor
func checkRerunsCarryTheNotes() async {
    print("")
    print("Re-runs that carry the notes")

    let held = HeldCritique()
    let model = CritiqueModel(service: held)
    let draft = """
        # Shipping Faster

        Our deploys take forty minutes because every test runs on every change.

        Most teams never measure where that time goes, so they guess.

        Caching the dependency install alone saved us twelve minutes a build.

        The rest came from splitting the suite by what each change could touch.
        """
    let first = [
        CritiqueFinding(
            severity: .high, category: "Logic and credibility",
            location: "paragraph 1",
            quote: "every test runs on every change", why: "Every test? Say which."
        ),
        CritiqueFinding(
            severity: .medium, category: "Clarity and precision",
            location: "paragraph 2",
            quote: "so they guess", why: "Who guesses, and at what?"
        ),
        CritiqueFinding(
            severity: .low, category: "Evidence",
            location: "paragraph 3",
            quote: "saved us twelve minutes a build", why: "Out of how many?"
        ),
        CritiqueFinding(
            severity: .low, category: "Clarity and precision",
            location: "paragraph 4",
            quote: "splitting the suite", why: "Splitting it how?"
        ),
    ]
    model.applyForChecking(
        CritiqueReport(jobRead: "A post for developers.", overall: "Close.", findings: first),
        for: draft
    )
    let (idA, idB, idC, idD) = (first[0].id, first[1].id, first[2].id, first[3].id)
    func note(_ id: UUID) -> CritiqueModel.Item? { model.item(withID: id) }
    func words(_ id: UUID, in text: String) -> String? {
        guard let range = note(id)?.range,
              NSMaxRange(range) <= (text as NSString).length
        else { return nil }
        return (text as NSString).substring(with: range)
    }
    check(
        "every note is anchored to begin with",
        model.items.count == 4 && model.stillApplyingCount == 4,
        "\(model.items.count) notes, \(model.stillApplyingCount) still applying"
    )

    // Typing in a passage is the author acting on its note. It used to keep
    // counting until they found the card and pressed Done.
    let scoreBefore = model.score
    let reworded = draft.replacingOccurrences(of: "so they guess", with: "so they mostly guess")
    model.noteCurrentText(reworded)
    check(
        "typing inside a noted passage marks the note edited",
        note(idB)?.isEdited == true && !model.outstanding.contains { $0.id == idB },
        "edited \(String(describing: note(idB)?.isEdited))"
    )
    check(
        "and it stops counting at once",
        model.score > scoreBefore && model.stillApplyingCount == 3,
        "score \(scoreBefore) -> \(model.score), "
            + "\(model.stillApplyingCount) still applying"
    )
    check(
        "an edited note gives up its shading",
        !model.highlights.contains { $0.id == idB },
        "its passage is still shaded"
    )
    // Except while it is the one the author is working on: the shading is
    // what shows how far the passage still runs.
    model.press(note(idB)!)
    check(
        "unless it is the note selected",
        model.highlights.contains { $0.id == idB },
        "selecting it did not shade it"
    )
    model.selectedFindingID = nil

    model.noteCurrentText(draft)
    check(
        "taking the edit back makes it a note again",
        note(idB)?.isEdited == false && model.score == scoreBefore,
        "edited \(String(describing: note(idB)?.isEdited)), score \(model.score)"
    )

    // Undo after cutting the end off a passage puts the words back *beside*
    // the shortened mark, which is outside it by the boundary rule — so
    // following the edit alone would leave a note the author has taken
    // straight back marked Edited.
    let cut = draft.replacingOccurrences(
        of: "every test runs on every change.", with: "every test runs."
    )
    model.noteCurrentText(cut)
    check(
        "cutting the end off a passage marks its note edited",
        note(idA)?.isEdited == true,
        "edited \(String(describing: note(idA)?.isEdited))"
    )
    model.noteCurrentText(draft)
    check(
        "and undoing the cut finds the whole passage again",
        note(idA)?.isEdited == false
            && words(idA, in: draft) == "every test runs on every change",
        "edited \(String(describing: note(idA)?.isEdited)), "
            + "marks \"\(words(idA, in: draft) ?? "nothing")\""
    )

    let beside = draft.replacingOccurrences(
        of: "twelve minutes a build.", with: "twelve minutes a build, on average."
    )
    model.noteCurrentText(beside)
    check(
        "typing beside a passage leaves its note alone",
        note(idC)?.isEdited == false && note(idC)?.isOutstanding == true
            && words(idC, in: beside) == "saved us twelve minutes a build",
        "edited \(String(describing: note(idC)?.isEdited)), "
            + "marks \"\(words(idC, in: beside) ?? "nothing")\""
    )
    model.noteCurrentText(draft)

    // Re-run on the draft the critique already describes, with nothing
    // waiting on it: half a minute and a request for the same notes in other
    // words. The rail says so instead.
    let askedBefore = held.asked
    model.request(on: draft, documentURL: nil)
    await settle()
    check(
        "re-running an unchanged draft says so rather than asking again",
        model.showsUnchangedNotice && !model.isRunning && held.asked == askedBefore,
        "notice \(model.showsUnchangedNotice), running \(model.isRunning), "
            + "\(held.asked - askedBefore) requests"
    )

    let storedHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    UserDefaults.standard.set(CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey)
    defer {
        if let storedHand {
            UserDefaults.standard.set(storedHand, forKey: CritiqueHand.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
        }
    }
    /// The rail as drawn, read back from its pixels.
    func drawnRail(isStale: Bool) -> String {
        let host = NSHostingView(rootView: CritiqueSidebar(
            critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isStale: isStale, onRerun: {}, onRerunChanges: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 2000)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if let path = ProcessInfo.processInfo.environment["MDE_CARRY_PNG"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = path.replacingOccurrences(
                of: ".png", with: isStale ? "-after.png" : "-unchanged.png"
            )
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: file))
            print("  wrote \(file)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }
    check(
        "and the rail draws that",
        drawnRail(isStale: false)
            .contains(readable("Nothing has changed since this critique")),
        "the notice is not legible on the rail"
    )

    // Anything that waits on a critique is a reason to run one.
    model.setResolution(.completed, for: idC)
    check(
        "marking a note Done puts the notice away",
        !model.showsUnchangedNotice,
        "it is still up"
    )

    let rewritten = draft.replacingOccurrences(of: "so they guess", with: "so they just guess")
    model.noteCurrentText(rewritten)
    model.request(on: rewritten, documentURL: nil)
    await settle { held.isWaiting }
    let sent = held.lastPrevious
    check(
        "a re-run of one changed paragraph asks about that paragraph's note",
        model.isRunning && sent.contains { $0.quote == "so they guess" }
            && (held.lastFocus ?? "").contains("so they just guess"),
        "running \(model.isRunning), sent \(sent.map(\.quote)), "
            + "focus \(held.lastFocus ?? "none")"
    )
    check(
        "and about the note marked Done elsewhere, which is waiting on it",
        sent.contains { $0.quote == "saved us twelve minutes a build" },
        "sent \(sent.map(\.quote))"
    )
    check(
        "but not about the paragraphs it was not asked to read",
        !sent.contains { $0.quote == "every test runs on every change" }
            && !sent.contains { $0.quote == "splitting the suite" },
        "sent \(sent.map(\.quote))"
    )
    let keyB = sent.first { $0.quote == "so they guess" }?.key ?? "?"
    let repeated = CritiqueFinding(
        severity: .high, category: "Logic and credibility",
        location: "paragraph 1",
        quote: "because every test runs on every change",
        why: "Is it really every test?"
    )
    let added = CritiqueFinding(
        severity: .medium, category: "Structure and pacing",
        location: "paragraph 2",
        quote: "Most teams never measure where that time goes",
        why: "Which teams? Say how you know."
    )
    held.answer(
        CritiqueReport(
            jobRead: "A post for developers.", overall: "Closer.",
            findings: [repeated, added]
        ),
        verdicts: [keyB: .stillApplies(quote: "so they just guess", location: "paragraph 2")]
    )
    await settle { !model.isRunning }

    check(
        "a rewrite the critic says did not work comes back as the same note, open",
        note(idB)?.isOutstanding == true && note(idB)?.finding.quote == "so they just guess"
            && words(idB, in: rewritten) == "so they just guess",
        "outstanding \(String(describing: note(idB)?.isOutstanding)), "
            + "quotes \"\(note(idB)?.finding.quote ?? "nothing")\""
    )
    check(
        "a note marked Done that the critic does not raise again is fixed",
        note(idC)?.isFixed == true
            && !(model.report?.findings.contains { $0.id == idC } ?? true),
        "fixed \(String(describing: note(idC)?.isFixed))"
    )
    check(
        "the notes it was not asked about are kept as they were",
        note(idA)?.isOutstanding == true && note(idD)?.isOutstanding == true
            && words(idA, in: rewritten) == "every test runs on every change",
        "\(model.items.count) notes"
    )
    check(
        "a carried note said again in other words is not added twice",
        !model.items.contains { $0.finding.quote == repeated.quote },
        "the reworded repeat is in the rail beside the note it repeats"
    )
    check(
        "while something genuinely new is",
        model.items.contains { $0.id == added.id && $0.isOutstanding },
        "the new note is missing"
    )
    check(
        "the rail says what the run changed",
        model.lastChange == CritiqueCarry.Delta(fixed: 1, reopened: 1, new: 1)
            && model.lastChange?.summary == "1 fixed · 1 reopened · 1 new since the last critique.",
        "it says \(model.lastChange?.summary ?? "nothing")"
    )
    check(
        "the saved critique keeps what was fixed, apart from what still stands",
        model.history.latest?.fixed?.map(\.id) == [idC]
            && model.report?.findings.count == 4,
        "fixed \(model.history.latest?.fixed?.map(\.quote) ?? []), "
            + "\(model.report?.findings.count ?? -1) standing"
    )
    check(
        "and a critique of the draft as it stands, with nothing waiting, is the critic's word",
        model.isConfirmed,
        "it is not confirmed"
    )

    // The whole draft, with an open note found fixed and a dismissed one
    // found still there.
    model.setResolution(.dismissed, for: idD)
    model.run(on: rewritten, documentURL: nil, scope: .whole)
    await settle { held.isWaiting }
    let wholeSent = held.lastPrevious
    check(
        "a whole re-run asks about every standing note",
        wholeSent.count == 4 && held.lastFocus == nil,
        "sent \(wholeSent.map(\.quote)), focus \(held.lastFocus ?? "none")"
    )
    check(
        "but not again about the one already found fixed",
        !wholeSent.contains { $0.quote == "saved us twelve minutes a build" },
        "sent \(wholeSent.map(\.quote))"
    )
    let keyA = wholeSent.first { $0.quote == "every test runs on every change" }?.key ?? "?"
    let keyD = wholeSent.first { $0.quote == "splitting the suite" }?.key ?? "?"
    held.answer(
        CritiqueReport(jobRead: "A post for developers.", overall: "Nearly.", findings: []),
        verdicts: [keyA: .fixed, keyD: .stillApplies(quote: nil, location: nil)]
    )
    await settle { !model.isRunning }
    check(
        "an open note the critic finds fixed is marked fixed",
        note(idA)?.isFixed == true,
        "fixed \(String(describing: note(idA)?.isFixed))"
    )
    check(
        "a dismissed note the critic still sees stays dismissed",
        note(idD)?.resolution == .dismissed && note(idD)?.isFixed == false,
        "it is \(String(describing: note(idD)?.resolution))"
    )
    check(
        "and notes it said nothing about stay open",
        note(idB)?.isOutstanding == true && note(added.id)?.isOutstanding == true,
        "\(model.outstanding.count) outstanding"
    )
    check(
        "a note found fixed is the last run's news, not every run's",
        note(idC) == nil && model.lastChange == CritiqueCarry.Delta(fixed: 1, reopened: 0, new: 0),
        "the earlier fixed note is still listed, change \(model.lastChange?.summary ?? "none")"
    )

    // Reopened later, the critique still says what its run fixed.
    model.show(revision: model.history.revisions.last?.id)
    model.show(revision: nil)
    check(
        "putting the newest critique back on screen keeps its fixed notes",
        note(idA)?.isFixed == true && note(idD)?.resolution == .dismissed,
        "fixed \(String(describing: note(idA)?.isFixed))"
    )

    // The gate again, after a run, and a note marked Done opening it.
    let askedAfter = held.asked
    model.request(on: rewritten, documentURL: nil)
    check(
        "re-running straight after a critique says nothing has changed",
        model.showsUnchangedNotice && held.asked == askedAfter,
        "notice \(model.showsUnchangedNotice), \(held.asked - askedAfter) requests"
    )
    model.setResolution(.completed, for: added.id)
    model.request(on: rewritten, documentURL: nil)
    await settle { held.isWaiting }
    check(
        "marking a note Done is enough to run it",
        held.asked == askedAfter + 1 && model.isRunning,
        "\(held.asked - askedAfter) requests"
    )
    held.answer(CritiqueReport(jobRead: "A post for developers.", overall: "Ready.", findings: []))
    await settle { !model.isRunning }
    check(
        "and the critic agreeing fixes it",
        note(added.id)?.isFixed == true,
        "fixed \(String(describing: note(added.id)?.isFixed))"
    )

    // Drawn: an Edited card and a Fixed one each say what they are.
    let again = rewritten.replacingOccurrences(of: "so they just guess", with: "so they simply guess")
    model.noteCurrentText(again)
    let drawn = drawnRail(isStale: true)
    for phrase in [
        "A later critique found this fixed.",
        "Changed since. The next critique checks it.",
        "1 fixed since the last critique.",
    ] {
        check(
            "the rail draws \"\(phrase)\"",
            legible(phrase, in: drawn),
            "not legible on the rail, which reads: \(drawn)"
        )
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
    model.setResolution(.completed, for: answered!.id)

    check(
        "answering one takes it out of the outstanding count",
        model.outstanding.count == outstandingBefore - 1,
        "\(model.outstanding.count) of \(outstandingBefore)"
    )
    check(
        "the score goes up when a note is marked Done",
        model.score > scoreBefore,
        "\(scoreBefore) -> \(model.score)"
    )
    // Dismissing is a decision not to act, and the draft is no better for it.
    // A score that rose for it let "Dismiss all" print "Ready" over a draft
    // nobody had touched.
    model.setResolution(.dismissed, for: answered!.id)
    check(
        "but not when it is dismissed",
        model.score == scoreBefore,
        "\(scoreBefore) -> \(model.score)"
    )
    let caption = CritiqueSidebar(
        critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: false, onRerun: {}, onRerunChanges: {}
    ).scoreCaption
    check(
        "and the rail says why the dismissed note still counts",
        caption?.contains("Dismissed notes still count") == true,
        "it says \(caption ?? "nothing")"
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
    // A hundred reached by ticking boxes is the author's word, not the
    // critic's, so it says so until a fresh critique agrees.
    let allDone = CritiqueModel()
    allDone.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: model.items.map(\.finding)),
        for: source
    )
    for item in allDone.items { allDone.setResolution(.completed, for: item.id) }
    check(
        "marking every note Done reaches a hundred",
        allDone.score == 100,
        "it reached \(allDone.score)"
    )
    check(
        "but says it looks ready, not that it is",
        allDone.verdict == "Looks ready" && !allDone.isConfirmed,
        "it says \"\(allDone.verdict)\""
    )
    let fresh = CritiqueModel()
    fresh.applyForChecking(CritiqueReport(jobRead: "", overall: "", findings: []), for: source)
    check(
        "a fresh critique with nothing to say is the one that says Ready",
        fresh.score == 100 && fresh.verdict == "Ready",
        "\(fresh.score), \"\(fresh.verdict)\""
    )
    let dismissedAll = CritiqueModel()
    dismissedAll.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: model.items.map(\.finding)),
        for: source
    )
    let untouched = dismissedAll.score
    for item in dismissedAll.items { dismissedAll.setResolution(.dismissed, for: item.id) }
    check(
        "dismissing every note leaves the score where it was",
        dismissedAll.score == untouched,
        "\(untouched) -> \(dismissedAll.score)"
    )
    // The summary's problems are the critic's verdict too. Every note Done
    // while it still lists two is not a finished draft.
    let listed = CritiqueModel()
    listed.applyForChecking(
        CritiqueReport(
            jobRead: "", overall: "",
            whatDoesNotWork: ["No example.", "The ending trails off."],
            findings: model.items.map(\.finding)
        ),
        for: source
    )
    for item in listed.items { listed.setResolution(.completed, for: item.id) }
    check(
        "problems the summary still lists keep it under a hundred",
        listed.score < 100,
        "it reached \(listed.score)"
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

    // The notes are written in whatever hand the reader picked, and a
    // handwriting face is not something the words can be reliably read back
    // from, so this drawing uses the system face and puts the choice back.
    let storedRailHand = UserDefaults.standard.string(forKey: CritiqueHand.storageKey)
    UserDefaults.standard.set(CritiqueHand.sans.rawValue, forKey: CritiqueHand.storageKey)
    // Every note in full and the summary open, which is the drawing the
    // checks below were written against. Closed is checked at the end.
    let restoreSummary = pinDefault(CritiqueSidebar.summaryExpandedKey, to: true)
    let restoreDensity = pinDefault(CritiqueSidebar.compactNotesKey, to: false)
    defer {
        if let storedRailHand {
            UserDefaults.standard.set(storedRailHand, forKey: CritiqueHand.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CritiqueHand.storageKey)
        }
        restoreSummary()
        restoreDensity()
    }

    let rail = CritiqueSidebar(
        critique: model,
        colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: true,
        onRerun: {}, onRerunChanges: {}
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

    // Most of what a note says cannot be found that way. A note you can press
    // draws its words unselectable — the selectable-text view laid over them
    // took the press — and with that view gone nothing in AppKit's tree holds
    // the string. So the words are read back from the drawing, which is also
    // the stronger claim: legible on the rail, not merely somewhere in a tree.
    // The tree is not consulted as a fallback, because it still holds the
    // words of a selectable note that has stopped drawing them.
    let drawnLines = recognisedText(in: host)
    let drawn = readable(drawnLines.joined(separator: " "))
    check(
        "the rail's drawing can be read back",
        !drawnLines.isEmpty,
        "the text recogniser found nothing on it"
    )
    func railShows(_ phrase: String) -> Bool {
        drawn.contains(readable(phrase))
    }

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
            railShows(expected),
            "not legible in the drawing (\(drawnLines.count) lines read; "
                + "the view tree has it: \(all.contains(expected)))"
        )
    }
    check(
        "an unanchored finding still gets a card, and says so",
        railShows("Not found in the document"),
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
        print("---- read from the drawing ----")
        for line in drawnLines { print("  · \(line)") }
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

    // Everything the bands below look for sits under the audience line, and
    // that line is as tall as the brief in it, so its height is taken from a
    // drawing of it rather than assumed. At the offsets measured before it
    // went in, the score and the stale notice both read as missing.
    let briefLine = NSHostingView(rootView: CritiqueBriefLine(
        critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
        onRerun: {}
    ).frame(width: host.bounds.width))
    // And the rule under it.
    let below = briefLine.fittingSize.height + 1
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  the audience line takes \(Int(below))pt")
    }

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
        let searchTo = min(rep.pixelsHigh, Int((280 + below) * scale))
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
        fromTop: 200 + below, height: host.bounds.height - 200 - below,
        excluding: bannerWash
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

    let scoreInk = saturatedArea(fromTop: 58 + below, height: 64)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  saturated ink in the score band: \(Int(scoreInk))pt²")
        for top in stride(from: below, to: 200.0 + below, by: 20.0) {
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

    let noticeRun = widestRun(fromTop: 36 + below, height: 52)
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  widest run in the notice band: \(Int(noticeRun))pt")
    }
    check(
        "a stale critique says so rather than drifting quietly",
        noticeRun > 150,
        "widest run was \(Int(noticeRun))pt, which is text, not a panel"
    )

    // The summary as it opens: the overall read, and a switch naming what is
    // behind it. Both lists open on every critique filled the first screen
    // of the rail before a single note.
    UserDefaults.standard.set(false, forKey: CritiqueSidebar.summaryExpandedKey)
    let closed = NSHostingView(rootView: CritiqueSidebar(
        critique: model,
        colorTheme: EditorColorTheme(color: .blue, mode: .light),
        isStale: true,
        onRerun: {}, onRerunChanges: {}
    ))
    closed.frame = host.frame
    window.contentView = closed
    closed.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    closed.layoutSubtreeIfNeeded()
    let closedRead = readable(recognisedText(in: closed).joined(separator: " "))
    window.orderOut(nil)
    check(
        "the summary opens on its one-sentence read",
        legible("Clear, but the claim needs support.", in: closedRead),
        "read \"\(closedRead.prefix(400))\""
    )
    check(
        "with a switch that says what is behind it",
        legible("What works (1) and what", in: closedRead),
        "read \"\(closedRead.prefix(400))\""
    )
    check(
        "and the lists themselves behind it",
        !legible("The mechanism is described correctly.", in: closedRead)
            && !legible("Nothing is grounded in an example.", in: closedRead),
        "read \"\(closedRead.prefix(400))\""
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
                // The strip's switches: the one narrowed to is filled with
                // its severity's colour, and its count is written over that.
                ("the \(name) switch while it is chosen",
                 primary, over(srgb(severity.tint).withAlphaComponent(0.18), canvas), 4.5),
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
            ("a switch on the strip that is not chosen",
             srgb(CritiqueInk.quiet(on: mode)), canvas, 4.5),
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

/// The rail is always there, and says what it needs before it needs it.
///
/// The rail used to appear only once it had something in it, so the feature
/// was invisible until you knew it existed. Now the first thing most people
/// see is the set-up state, and that state has to name the thing it wants
/// rather than offering a button that fails.
@MainActor
func checkTheRailAsksForWhatItNeeds() {
    print("")
    print("A rail with nothing in it yet")

    let model = CritiqueModel()
    check(
        "the rail is on screen before there is anything in it",
        model.isPresented,
        "it is hidden until it has a report, which is how it went unnoticed"
    )

    let theme = EditorColorTheme(color: .blue, mode: .light)
    let rail = CritiqueSidebar(
        critique: model, colorTheme: theme, isStale: false,
        onRerun: {}, onRerunChanges: {}
    )
    let host = NSHostingView(rootView: AnyView(rail))
    host.frame = NSRect(x: 0, y: 0, width: 340, height: 600)
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()

    // Asserted on the state rather than on the drawn words: SwiftUI draws
    // these without a backing NSTextField, and the accessibility walk that
    // other checks here use returns nothing at all for this rail — measured as
    // two empty strings. A check keyed on that passes for every state.
    let expected: CritiqueSidebar.State = CritiqueCredentials.isConfigured
        ? .nothingYet
        : .needsSetUp
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  state: \(rail.state), configured: "
            + "\(CritiqueCredentials.isConfigured)")
    }
    check(
        "and it shows \(expected) with no report and no key",
        rail.state == expected,
        "it shows \(rail.state)"
    )

    // And it is actually drawn — a state that renders nothing would satisfy
    // the assertion above while showing an empty panel.
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        check("and the rail draws something", false)
        return
    }
    host.cacheDisplay(in: host.bounds, to: rep)
    let page = EditorColorTheme(color: .blue, mode: .light)
        .editorBackgroundColor.usingColorSpace(.sRGB)!
    var inked = 0
    for y in 0..<rep.pixelsHigh {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c: NSColor = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            else { continue }
            let dr: CGFloat = abs(c.redComponent - page.redComponent)
            let dg: CGFloat = abs(c.greenComponent - page.greenComponent)
            let db: CGFloat = abs(c.blueComponent - page.blueComponent)
            if dr + dg + db > 0.12 { inked += 1 }
        }
    }
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  inked pixels: \(inked)")
    }

    // The rail offers the thing you came for.
    //
    // It used to say "No critique yet." and stop there — a statement of fact
    // with nothing to do about it, in a panel whose whole purpose is one
    // action. The action is now on screen in both empty states.
    check(
        "pressing the rail's button with a usable provider runs a critique",
        CritiqueCredentials.isConfigured ? rail.buttonAction == .run : true,
        "it would \(rail.buttonAction) instead"
    )

    // And with no key it asks for one rather than running into a failure that
    // was certain before the request was made. Checked by taking the key away
    // for the length of the check — the provider is a real preference on a
    // real machine, so it is put back.
    let storedProvider = UserDefaults.standard.string(
        forKey: CritiqueProvider.storageKey
    )
    UserDefaults.standard.set(
        CritiqueProvider.openAI.rawValue, forKey: CritiqueProvider.storageKey
    )
    let hadKey = CritiqueCredentials.key(for: .openAI)
    _ = CritiqueCredentials.remove(for: .openAI)
    let unconfigured = CritiqueSidebar(
        critique: CritiqueModel(), colorTheme: theme, isStale: false,
        onRerun: {}, onRerunChanges: {}
    )
    check(
        "with a provider that needs a key and none set, it asks for the key",
        unconfigured.buttonAction == .askForKey,
        "it would \(unconfigured.buttonAction), which fails after the request"
    )
    check(
        "and that is the state the rail draws",
        unconfigured.state == .needsSetUp,
        "it shows \(unconfigured.state)"
    )
    if let hadKey { _ = CritiqueCredentials.store(hadKey, for: .openAI) }
    if let storedProvider {
        UserDefaults.standard.set(storedProvider, forKey: CritiqueProvider.storageKey)
    } else {
        UserDefaults.standard.removeObject(forKey: CritiqueProvider.storageKey)
    }
    // And it is really laid out beside the document, not merely constructed.
    // `isPresented` returning true is not the same as the pane rendering it —
    // the pane has its own condition, and that is where this went wrong once.
    let paneTheme = EditorColorTheme(color: .blue, mode: .light)
    let pane = ResizableRichTextPreview(
        text: .constant("# Title\n\nWords.\n"),
        documentURL: nil,
        session: MarkdownEditorSession(fileURL: nil),
        colorTheme: paneTheme,
        preferredWidth: .constant(620),
        minimumWidth: 320,
        critique: model,
        hostsRail: true
    )
    let paneHost = NSHostingView(rootView: AnyView(pane))
    paneHost.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    paneHost.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    paneHost.layoutSubtreeIfNeeded()
    // The rail is a fixed-width strip in the row. Looked for by that width,
    // because it is the one thing in the pane with it.
    //
    // Not "is anything narrower than the pane", which was the first version
    // and passed on a 29pt subview while the rail was absent entirely.
    // Looked for in the drawn pixels, not in the view tree.
    //
    // Only an `NSViewRepresentable` leaves an NSView behind; the rail is
    // ordinary SwiftUI and leaves none. A check hunting the tree for a 356pt
    // view reported the rail missing while it was on screen — the widths it
    // could see were the scroll view's 820 and the host's 1200 and nothing
    // else.
    guard let paneRep = paneHost.bitmapImageRepForCachingDisplay(
        in: paneHost.bounds
    ) else {
        check("the pane can be drawn", false)
        return
    }
    paneHost.cacheDisplay(in: paneHost.bounds, to: paneRep)
    let paneScale = CGFloat(paneRep.pixelsWide) / paneHost.bounds.width
    let pagePaper = paneTheme.editorBackgroundColor.usingColorSpace(.sRGB)!
    // The rail sits at the trailing edge of the row.
    var railInk = 0
    for y in 0..<paneRep.pixelsHigh {
        for x in stride(
            from: paneRep.pixelsWide - Int(340 * paneScale),
            to: paneRep.pixelsWide,
            by: 2
        ) {
            guard let c: NSColor = paneRep.colorAt(x: x, y: y)?
                .usingColorSpace(.sRGB) else { continue }
            let dr: CGFloat = abs(c.redComponent - pagePaper.redComponent)
            let dg: CGFloat = abs(c.greenComponent - pagePaper.greenComponent)
            let db: CGFloat = abs(c.blueComponent - pagePaper.blueComponent)
            if dr + dg + db > 0.12 { railInk += 1 }
        }
    }
    if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
        print("  ink in the trailing band: \(railInk)")
    }
    check(
        "and the pane lays it out beside the document",
        railInk > 300,
        "only \(railInk) pixels are drawn where the rail belongs"
    )

    // Docked, not floating beside it.
    //
    // The notes are about the text they sit next to, so the rail's leading edge
    // is the document's trailing edge. It used to be a 16pt gutter past a page
    // that itself ended some way past the writing, which drew two faint rules
    // with a strip of empty page between them and read as a divider between two
    // panes rather than as a margin on one document.
    //
    // Measured as the distance from the document's edge to the first ink in the
    // rail. That has to be small — a card's own padding — and the check is that
    // it is not a gutter's worth on top of it.
    //
    // The document's edge is found from the page colour: the writing column and
    // the rail are the same paper, so the boundary is where the *rules* are, and
    // those are the only near-full-height columns of non-paper pixels.
    func fullHeightRule(nearestTo target: Int, in rep: NSBitmapImageRep) -> Int? {
        var best: (x: Int, run: Int)?
        for x in stride(from: rep.pixelsWide - 1, through: 0, by: -1) {
            var run = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                guard let c: NSColor = rep.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                let dr: CGFloat = abs(c.redComponent - pagePaper.redComponent)
                let dg: CGFloat = abs(c.greenComponent - pagePaper.greenComponent)
                let db: CGFloat = abs(c.blueComponent - pagePaper.blueComponent)
                if dr + dg + db > 0.02 { run += 1 }
            }
            if run > (rep.pixelsHigh / 4) * 8 / 10 {
                if best == nil || abs(x - target) < abs(best!.x - target) {
                    best = (x, run)
                }
            }
        }
        return best?.x
    }
    // The first ink to the right of the document's edge.
    if let edge = fullHeightRule(nearestTo: paneRep.pixelsWide / 2, in: paneRep) {
        var firstInk: Int?
        outer: for x in (edge + 2)..<paneRep.pixelsWide {
            for y in stride(from: 0, to: paneRep.pixelsHigh, by: 3) {
                guard let c: NSColor = paneRep.colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB) else { continue }
                let dr: CGFloat = abs(c.redComponent - pagePaper.redComponent)
                let dg: CGFloat = abs(c.greenComponent - pagePaper.greenComponent)
                let db: CGFloat = abs(c.blueComponent - pagePaper.blueComponent)
                if dr + dg + db > 0.12 { firstInk = x; break outer }
            }
        }
        let gap = firstInk.map { Double($0 - edge) / Double(paneScale) } ?? .infinity
        if ProcessInfo.processInfo.environment["MDE_DUMP_RAIL"] != nil {
            print("  document edge at \(edge)px, first rail ink \(String(describing: firstInk)), gap \(gap)pt")
        }
        check(
            "the rail is docked against the document, not floating beside it",
            gap < 30,
            "there are \(Int(gap))pt between the document's edge and the rail"
        )
    } else {
        check("the document's edge can be found", false, "no full-height rule")
    }

    check(
        "and the rail draws something",
        inked > 400,
        "only \(inked) pixels differ from the page, so the panel is blank"
    )
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

/// A note whose fix is a straight swap makes it, and takes it back.
///
/// Every way this goes wrong is quiet. A suggestion applied twice reads as a
/// typo the author made — "good enough enough" — and a note that cannot tell
/// its own words came back goes on saying Applied about a sentence that is
/// exactly as criticised. Both look like working features on screen.
@MainActor
func checkApplyingASuggestion() {
    print("")
    print("Applying a suggestion")

    let draft = """
        # Caching

        Caching is good for most apps, and each one has it own tradeoffs.

        The tradeoff is staleness, and it is “genuinely” hard.
        """
    let spelling = CritiqueFinding(
        severity: .medium, category: "Grammar and mechanics", location: "paragraph 2",
        quote: "each one has it own tradeoffs", why: "Possessive, not a contraction.",
        fix: "Change \"it\" to \"its\".", replacement: "each one has its own tradeoffs"
    )
    let hedge = CritiqueFinding(
        severity: .low, category: "Clarity and precision", location: "paragraph 2",
        quote: "good", why: "Good how?", fix: "Say how good.", replacement: "good enough"
    )
    let claim = CritiqueFinding(
        severity: .high, category: "Logic and credibility", location: "paragraph 3",
        quote: "The tradeoff is staleness", why: "How stale?",
        direction: "Say how stale, and for whom."
    )
    // Quoted with straight quotes where the draft has curly ones.
    let retyped = CritiqueFinding(
        severity: .low, category: "Voice and tone", location: "paragraph 3",
        quote: "it is \"genuinely\" hard", why: "Scare quotes.",
        fix: "Drop the word.", replacement: "it is hard"
    )
    let model = CritiqueModel()
    model.attach(to: nil, text: draft)
    model.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: [spelling, hedge, claim, retyped]),
        for: draft
    )
    func note(_ finding: CritiqueFinding) -> CritiqueModel.Item? {
        model.item(withID: finding.id)
    }
    func state(_ finding: CritiqueFinding) -> String {
        note(finding)?.standing?.label ?? "outstanding"
    }

    // The editor's half, as `MarkdownEditorSession.replaceSourceText` does it:
    // the words at the range checked, replaced, and the draft handed back.
    var text = draft
    var made: [CritiqueModel.Swap] = []
    func replace(_ swap: CritiqueModel.Swap) -> String? {
        let source = text as NSString
        guard NSMaxRange(swap.range) <= source.length,
              source.substring(with: swap.range) == swap.expected
        else { return nil }
        made.append(swap)
        text = source.replacingCharacters(in: swap.range, with: swap.replacement)
        return text
    }
    /// A change that did not come from the rail — typing, ⌘Z, ⌘⇧Z — arriving
    /// the way the view's `onChange` delivers every one.
    func edit(_ next: String) {
        text = next
        model.noteCurrentText(next)
    }
    func words(_ finding: CritiqueFinding) -> String {
        guard let range = note(finding)?.range,
              NSMaxRange(range) <= (text as NSString).length
        else { return "nothing" }
        return (text as NSString).substring(with: range)
    }

    check(
        "a straight swap is offered, and a fix that needs the author is not",
        note(spelling)?.suggestion == "each one has its own tradeoffs"
            && note(hedge)?.suggestion == "good enough"
            && note(claim)?.suggestion == nil,
        "spelling offers \(note(spelling)?.suggestion ?? "nothing"), "
            + "the claim offers \(note(claim)?.suggestion ?? "nothing")"
    )
    check(
        "nor is one for a quote found only by allowing for retyping",
        note(retyped)?.isAnchored == true && note(retyped)?.suggestion == nil,
        "anchored: \(note(retyped)?.isAnchored == true), "
            + "offers \(note(retyped)?.suggestion ?? "nothing")"
    )

    let scoreBefore = model.score
    let order = model.items.map(\.id)
    check("Apply makes the change", model.applySuggestion(for: spelling.id, using: replace))
    // What the view's `onChange` does next. The rail has already been told.
    model.noteCurrentText(text)
    check(
        "the draft reads as the critic suggested",
        text.contains("each one has its own tradeoffs") && !text.contains("has it own"),
        text
    )
    check(
        "as one change Undo can name",
        made.count == 1 && made.last?.name == "Apply Suggestion",
        made.map(\.name).joined(separator: ", ")
    )
    check(
        "the note says Applied, and stops counting",
        note(spelling)?.standing == .applied && note(spelling)?.counts == false
            && model.score > scoreBefore,
        "\(state(spelling)), score \(scoreBefore) then \(model.score)"
    )
    check(
        "it stays where it was pressed, marking the new words",
        model.items.map(\.id) == order && words(spelling) == "each one has its own tradeoffs",
        "it marks \"\(words(spelling))\""
    )
    check(
        "the other marks move with their words",
        words(claim) == "The tradeoff is staleness" && words(hedge) == "good",
        "the claim marks \"\(words(claim))\""
    )
    check("and an applied note offers no second Apply", note(spelling)?.suggestion == nil)

    let applied = text
    edit(draft)
    check(
        "Undo puts the note back as it was",
        note(spelling)?.isOutstanding == true && note(spelling)?.suggestion != nil
            && words(spelling) == "each one has it own tradeoffs" && model.score == scoreBefore,
        "\(state(spelling)), marking \"\(words(spelling))\", score \(model.score)"
    )
    edit(applied)
    check(
        "and Redo applies it again",
        note(spelling)?.standing == .applied && words(spelling) == "each one has its own tradeoffs",
        "\(state(spelling)), marking \"\(words(spelling))\""
    )

    // A suggestion that keeps the quoted words and adds to them. The added
    // words land beside the passage rather than in it, which every other
    // edit takes as typing next to a note.
    check("a suggestion that adds to the words applies", model.applySuggestion(for: hedge.id, using: replace))
    check(
        "and its mark takes the added words in",
        note(hedge)?.standing == .applied && words(hedge) == "good enough",
        "\(state(hedge)), marking \"\(words(hedge))\""
    )
    let addedTo = text
    let takenBack = addedTo.replacingOccurrences(of: "good enough", with: "good")
    edit(takenBack)
    check(
        "Undo brings it back, though the edit is worked out a character late",
        note(hedge)?.isOutstanding == true && words(hedge) == "good",
        "\(state(hedge)), marking \"\(words(hedge))\""
    )
    edit(addedTo)
    check(
        "and Redo applies it, though its words land beside the passage",
        note(hedge)?.standing == .applied && words(hedge) == "good enough",
        "\(state(hedge)), marking \"\(words(hedge))\""
    )
    check(
        "after which there is nothing to apply twice",
        note(hedge)?.suggestion == nil
            && !model.applySuggestion(for: hedge.id, using: replace)
            && !text.contains("enough enough"),
        text
    )

    // Typed by hand, a letter at a time, the way somebody who read the note
    // and did not see the button would.
    edit(takenBack)
    let after = (takenBack as NSString).range(of: "good").location + 4
    var typed = takenBack as NSString
    for (offset, letter) in " enough".enumerated() {
        typed = typed.replacingCharacters(
            in: NSRange(location: after + offset, length: 0), with: String(letter)
        ) as NSString
        edit(typed as String)
    }
    check(
        "typing the suggestion in counts as applying it",
        note(hedge)?.standing == .applied && words(hedge) == "good enough",
        "\(state(hedge)), marking \"\(words(hedge))\""
    )

    // The way back that is not ⌘Z: undo walks back through everything typed
    // since, and this takes back the one passage.
    check("Revert puts the words back", model.revertSuggestion(for: spelling.id, using: replace))
    check(
        "the original words, as one change Undo can name",
        text.contains("each one has it own tradeoffs") && made.last?.name == "Revert Suggestion",
        text
    )
    check(
        "and the note is outstanding again",
        note(spelling)?.isOutstanding == true && words(spelling) == "each one has it own tradeoffs",
        "\(state(spelling)), marking \"\(words(spelling))\""
    )

    // The draft moved on in the editor before the rail heard about it — a
    // keystroke the view has not yet reported.
    let unreported = text.replacingOccurrences(of: "each one has", with: "every one has")
    text = unreported
    let swapsBefore = made.count
    check(
        "Apply against words that have moved on changes nothing",
        !model.applySuggestion(for: spelling.id, using: replace)
            && text == unreported && made.count == swapsBefore,
        text
    )
    edit(unreported)
    edit(unreported.replacingOccurrences(of: "every one has", with: "each one has"))

    // Opened again later: the saved critique is anchored afresh against a
    // draft that took two of its suggestions, one of which no longer
    // contains the words it was quoted on.
    check("Apply again", model.applySuggestion(for: spelling.id, using: replace))
    model.show(revision: nil)
    check(
        "a suggestion that replaced its words is found applied on reopening",
        note(spelling)?.standing == .applied && words(spelling) == "each one has its own tradeoffs",
        "\(state(spelling)), marking \"\(words(spelling))\""
    )
    check(
        "and one that added to them is not offered a second time",
        note(hedge)?.standing == .applied && words(hedge) == "good enough"
            && note(hedge)?.suggestion == nil,
        "\(state(hedge)), marking \"\(words(hedge))\""
    )

    // The critique of a draft that already reads as the suggestion — typed in
    // where nothing was watching. Apply says so rather than adding it again.
    let already = CritiqueModel()
    let alreadyText = "Caching is good enough for most apps."
    already.attach(to: nil, text: alreadyText)
    already.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: [hedge]),
        for: alreadyText
    )
    text = alreadyText
    let applying = already.applySuggestion(for: hedge.id, using: replace)
    check(
        "a suggestion already in place is marked, not made again",
        applying && text == alreadyText
            && already.item(withID: hedge.id)?.standing == .applied,
        "\(text) — \(already.item(withID: hedge.id)?.standing?.label ?? "outstanding")"
    )

    // Drawn: the words it would put in, and the button that does it.
    let shown = CritiqueModel()
    shown.attach(to: nil, text: draft)
    shown.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: [spelling]),
        for: draft
    )
    func drawn(replacing: Bool) -> String {
        let host = NSHostingView(rootView: CritiqueSidebar(
            critique: shown, colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isStale: false, onRerun: {}, onRerunChanges: {},
            replaceText: replacing ? { _ in nil } : nil
        ))
        host.frame = NSRect(x: 0, y: 0, width: 356, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if replacing, let path = ProcessInfo.processInfo.environment["MDE_APPLY_PNG"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            print("  wrote \(path)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }
    let withApply = drawn(replacing: true)
    check(
        "the card shows the suggestion and an Apply button",
        withApply.contains("suggested")
            && withApply.contains(readable("each one has its own tradeoffs"))
            && withApply.contains("apply"),
        withApply
    )
    check(
        "and offers none where there is no draft to change",
        !drawn(replacing: false).contains("suggested")
    )
}

/// Who the draft is for: said by the author, or guessed once and then held.
///
/// The critic used to guess the reader afresh on every run and word the guess
/// differently each time — in grey, at the top of the summary, with no way to
/// say it was wrong. Every note is advice for that reader, so a wrong guess
/// was a rail of advice for somebody else, and a drifting one was two
/// critiques of one draft disagreeing for no reason anybody could see.
@MainActor
func checkTheBriefIsTheReader() async {
    print("")
    print("Holding every note to who the draft is for")

    let draft = String(
        repeating: "This paragraph says enough to be worth reading closely. ",
        count: 6
    )
    let finding = CritiqueFinding(
        severity: .medium, category: "Clarity", location: "paragraph 1",
        quote: "This paragraph says enough to be worth reading closely.",
        why: "Says it twice."
    )
    // The stores are the real ones, so the addresses are unique and
    // everything written under them is taken away again.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-\(UUID().uuidString).md")
    let saved = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-saved-\(UUID().uuidString).md")
    defer {
        for each in [url, saved] {
            CritiqueHistoryStore.save(CritiqueHistory(), for: each)
            CritiqueResolutionStore.save(CritiqueResolutions(), for: each)
            CritiqueBriefStore.save(nil, for: each)
        }
    }

    let held = HeldCritique()
    let model = CritiqueModel(service: held)

    /// The top of the rail as drawn, read back: the line is only as good as
    /// what a writer can see of it.
    func drawnLine(savingTo variable: String) -> String {
        let host = NSHostingView(rootView: CritiqueSidebar(
            critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isStale: false, onRerun: {}, onRerunChanges: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 356, height: 420)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if let path = ProcessInfo.processInfo.environment[variable],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path))
            print("  wrote \(path)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }

    model.attach(to: url, text: draft)
    // Nothing has been read yet, so there is nothing to call a guess. The
    // first version headed this empty line GUESSED in every new document.
    let unread = drawnLine(savingTo: "MDE_BRIEF_UNREAD_PNG")
    check(
        "before any critique the line claims no guess",
        model.brief == CritiqueBrief() && !model.brief.isGuess
            && unread.contains("audience and goal") && !unread.contains("guessed")
            && unread.contains(readable("Leave it empty and the critic will guess.")),
        unread
    )
    model.request(on: draft, documentURL: url)
    await settle { held.isWaiting }
    check(
        "with nobody named, the critic is left to guess",
        held.asked == 1 && held.lastBrief == nil,
        "it was told \(held.lastBrief?.text ?? "nothing") after \(held.asked) requests"
    )
    held.answer(CritiqueReport(
        jobRead: "A post for\n web developers new to caching. ",
        overall: "Close.", findings: [finding]
    ))
    await settle { !model.isRunning }
    let guess = CritiqueBrief("A post for web developers new to caching.", isGuess: true)
    check(
        "its read becomes the line, marked as a guess",
        model.brief == guess && model.authorBrief == nil && !model.isForAnotherReader,
        "\(model.brief)"
    )
    model.setBrief(" A post for web developers   new to caching. ")
    check(
        "accepting the guess as it stands leaves it a guess",
        model.brief == guess && CritiqueBriefStore.load(for: url) == nil,
        "\(model.brief)"
    )
    let guessed = drawnLine(savingTo: "MDE_BRIEF_GUESS_PNG")
    check(
        "the rail draws the guess, and the heading says it is one",
        guessed.contains("audience and goal") && guessed.contains("guessed")
            && guessed.contains(readable("A post for web developers new to caching.")),
        guessed
    )

    let edited = draft + "And a sentence that was not there before."
    model.noteCurrentText(edited)
    model.request(on: edited, documentURL: url)
    await settle { held.isWaiting }
    check(
        "the next critique is held to that guess rather than guessing again",
        held.lastBrief == guess,
        "it was told \(held.lastBrief.map { "\($0)" } ?? "nothing")"
    )
    held.answer(CritiqueReport(
        jobRead: "Developers who want a mental model of caching.",
        overall: "Closer.", findings: [finding]
    ))
    await settle { !model.isRunning }
    check(
        "and the reader does not drift with the critic's wording",
        model.brief == guess && model.history.revisions.count == 2,
        "\(model.brief), \(model.history.revisions.count) critiques"
    )

    // The author says who it is for. The draft has not changed, and that is
    // no longer a reason to decline: these notes were for somebody else.
    let senior = "Senior engineers who already cache; get them to measure first."
    model.setBrief("  Senior engineers\nwho already cache;  get them to measure first. ")
    check(
        "the author's words replace the guess, as one line",
        model.brief == CritiqueBrief(senior) && !model.brief.isGuess,
        "\(model.brief)"
    )
    check(
        "and are kept for the document",
        CritiqueBriefStore.load(for: url) == senior,
        CritiqueBriefStore.load(for: url) ?? "nothing was kept"
    )
    check(
        "the notes on screen say they were written for somebody else",
        model.isForAnotherReader && !model.canCritiqueChangesOnly,
        "isForAnotherReader \(model.isForAnotherReader)"
    )

    let corrected = drawnLine(savingTo: "MDE_BRIEF_PNG")
    check(
        "the rail draws the line, the brief, and the way to act on it",
        corrected.contains("audience and goal")
            && !corrected.contains("guessed")
            && corrected.contains(readable("Senior engineers who already cache"))
            && corrected.contains(readable("written for a different reader"))
            && corrected.contains(readable("Critique again")),
        corrected
    )

    let asked = held.asked
    model.request(on: edited, documentURL: url)
    await settle { held.isWaiting }
    check(
        "re-running an unchanged draft for a new reader is not declined",
        held.asked == asked + 1 && !model.showsUnchangedNotice,
        "\(held.asked - asked) requests, notice \(model.showsUnchangedNotice)"
    )
    check(
        "it is sent as the author's word",
        held.lastBrief == CritiqueBrief(senior),
        "it was told \(held.lastBrief.map { "\($0)" } ?? "nothing")"
    )
    check(
        "and it starts over: the whole draft, nothing carried from the old reader",
        held.lastFocus == nil && held.lastPrevious.isEmpty,
        "focus \(held.lastFocus ?? "none"), \(held.lastPrevious.count) carried"
    )
    let forSenior = CritiqueFinding(
        severity: .high, category: "Audience fit", location: "paragraph 1",
        quote: "This paragraph says enough to be worth reading closely.",
        why: "A senior engineer knows this already."
    )
    held.answer(CritiqueReport(jobRead: "Senior engineers.", overall: "Fine.", findings: [forSenior]))
    await settle { !model.isRunning }
    check(
        "once it lands, the notes are this reader's",
        !model.isForAnotherReader && model.lastChange == nil
            && model.items.map(\.finding.why) == ["A senior engineer knows this already."],
        model.items.map(\.finding.why).joined(separator: " / ")
    )
    check(
        "and the critique for the old reader is still in the history",
        model.history.revisions.count == 3
            && model.history.revisions.first?.brief == senior
            && model.history.revisions.dropFirst().first?.reader == guess.text,
        model.history.revisions.map(\.reader).joined(separator: " / ")
    )
    model.request(on: edited, documentURL: url)
    check(
        "asked again for the same reader and the same draft, it declines",
        model.showsUnchangedNotice && held.asked == asked + 1,
        "\(held.asked - asked) requests"
    )
    model.setBrief(senior + " ")
    check(
        "retyping the same brief changes nothing",
        model.showsUnchangedNotice && !model.isForAnotherReader,
        "isForAnotherReader \(model.isForAnotherReader)"
    )

    let reopened = CritiqueModel(service: HeldCritique())
    reopened.attach(to: url, text: edited)
    check(
        "reopening the document brings its reader back",
        reopened.brief == CritiqueBrief(senior) && !reopened.isForAnotherReader,
        "\(reopened.brief)"
    )

    // Cleared: the critic guesses again, and the line shows the new guess.
    model.setBrief("")
    check(
        "cleared, the line is empty and the notes are no longer for anybody named",
        model.brief.isEmpty && model.isForAnotherReader
            && CritiqueBriefStore.load(for: url) == "",
        "\(model.brief)"
    )
    model.request(on: edited, documentURL: url)
    await settle { held.isWaiting }
    check("the critic is left to guess again", held.lastBrief == nil)
    held.answer(CritiqueReport(jobRead: "Engineering managers.", overall: "Fine.", findings: [finding]))
    await settle { !model.isRunning }
    check(
        "and its new read is the line",
        model.brief == CritiqueBrief("Engineering managers.", isGuess: true)
            && CritiqueBriefStore.load(for: url) == nil,
        "\(model.brief), kept \(CritiqueBriefStore.load(for: url) ?? "nothing")"
    )

    // The first ⌘S of an untitled draft. This went through `attach`, which
    // took the new address for a new document and emptied the rail.
    let untitled = CritiqueModel(service: HeldCritique())
    untitled.attach(to: nil, text: draft)
    untitled.setBrief("Beginners.")
    untitled.applyForChecking(
        CritiqueReport(jobRead: "", overall: "", findings: [finding]), for: draft
    )
    untitled.setResolution(.dismissed, for: untitled.items[0].id)
    let notes = untitled.items.map(\.id)
    untitled.move(to: saved, text: draft)
    check(
        "saving an untitled draft keeps its critique on screen",
        untitled.report != nil && untitled.items.map(\.id) == notes
            && untitled.brief == CritiqueBrief("Beginners."),
        "\(untitled.items.count) notes, \(untitled.brief)"
    )
    let reread = CritiqueModel(service: HeldCritique())
    reread.attach(to: saved, text: draft)
    check(
        "and files it, its answers and its reader under the new name",
        reread.history.latest?.brief == "Beginners."
            && reread.brief == CritiqueBrief("Beginners.")
            && reread.items.first?.resolution == .dismissed,
        "\(reread.history.revisions.count) critiques, \(reread.brief)"
    )
    // A window with nothing of its own takes what is kept for the file,
    // rather than writing its emptiness over it.
    let opening = CritiqueModel(service: HeldCritique())
    opening.move(to: url, text: edited)
    check(
        "a window with no critique of its own shows the one kept for the file",
        opening.history.revisions.count == model.history.revisions.count
            && opening.report != nil,
        "\(opening.history.revisions.count) critiques"
    )
}

/// Return keeps what was typed, Esc puts the line back, and both hand the
/// keyboard to the draft.
///
/// Driven with key events through a real window rather than by calling the
/// model, because each of those is a promise the line prints under the field
/// while it is being typed in, and none of it is the model's doing: it is
/// SwiftUI's text field, its focus, and how AppKit's field editor routes the
/// two keys. Esc in particular is a key a field editor would otherwise spend
/// on completion.
@MainActor
func checkTheBriefLineTakesTheKeyboard() {
    print("")
    print("Typing in the audience line")

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("brief-keys-\(UUID().uuidString).md")
    defer {
        CritiqueHistoryStore.save(CritiqueHistory(), for: url)
        CritiqueResolutionStore.save(CritiqueResolutions(), for: url)
        CritiqueBriefStore.save(nil, for: url)
    }
    let model = CritiqueModel(service: HeldCritique())
    model.attach(to: url, text: "A draft.")
    model.applyForChecking(
        CritiqueReport(jobRead: "Developers new to caching.", overall: "", findings: []),
        for: "A draft."
    )
    var returned = 0
    let host = NSHostingView(rootView: CritiqueBriefLine(
        critique: model, colorTheme: EditorColorTheme(color: .blue, mode: .light),
        onRerun: {}, returnToDraft: { returned += 1 }
    ).frame(width: 356))
    host.frame = NSRect(x: 0, y: 0, width: 356, height: 200)
    // Titled, because a borderless window cannot take the keyboard.
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled],
        backing: .buffered, defer: false
    )
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    func spin(_ seconds: Double = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    spin(0.3)

    func field(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews {
            if let found = field(in: child) { return found }
        }
        return nil
    }
    guard let line = field(in: host) else {
        check("the line is a field that can be typed in", false, "no editable field was drawn")
        return
    }
    // Straight to the window, which is where the application would send them:
    // with the screen locked there is no key window for it to pick.
    func press(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: phase, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            ) else { continue }
            window.sendEvent(event)
        }
        spin(0.05)
    }
    func write(_ text: String) {
        for character in text { press(String(character), keyCode: 0) }
        spin()
    }
    func startTyping() -> Bool {
        let took = window.makeFirstResponder(line)
        spin(0.3)
        return took && line.currentEditor() != nil
    }
    let returnKey: UInt16 = 36, escape: UInt16 = 53

    check(
        "the line takes the keyboard",
        startTyping(),
        "the first responder is \(window.firstResponder.map { "\(type(of: $0))" } ?? "nothing")"
    )
    // Focus selects the line, so typing replaces the guess outright.
    write("Senior engineers.")
    press("\r", keyCode: returnKey)
    check(
        "Return keeps what was typed",
        model.brief == CritiqueBrief("Senior engineers.")
            && CritiqueBriefStore.load(for: url) == "Senior engineers.",
        "\(model.brief)"
    )
    check(
        "and hands the keyboard back to the draft",
        returned == 1 && line.currentEditor() == nil,
        "returned \(returned) times, still editing \(line.currentEditor() != nil)"
    )

    _ = startTyping()
    write("Somebody else entirely")
    press("\u{1b}", keyCode: escape)
    check(
        "Esc puts the line back as it was",
        model.brief == CritiqueBrief("Senior engineers.")
            && line.stringValue == "Senior engineers.",
        "the brief is \(model.brief), the line shows \(line.stringValue)"
    )
    check(
        "and hands the keyboard back too",
        returned == 2 && line.currentEditor() == nil,
        "returned \(returned) times, still editing \(line.currentEditor() != nil)"
    )

    // A second line is allowed while typing, and kept as one: the brief is
    // a sentence about a reader, not a document.
    _ = startTyping()
    write("Senior engineers")
    press("\r", keyCode: returnKey, .option)
    write("who already cache.")
    check(
        "Option-Return breaks the line without leaving it",
        line.currentEditor() != nil && returned == 2,
        "still editing \(line.currentEditor() != nil)"
    )
    press("\r", keyCode: returnKey)
    check(
        "and what it kept reads as one line",
        model.brief == CritiqueBrief("Senior engineers who already cache."),
        "\(model.brief)"
    )

    // Clicking somewhere else keeps the words, like leaving any field, and
    // leaves the keyboard wherever the click put it.
    _ = startTyping()
    write("Engineering managers.")
    window.makeFirstResponder(nil)
    spin(0.3)
    check(
        "leaving the line another way keeps what was typed",
        model.brief == CritiqueBrief("Engineering managers.") && returned == 3,
        "\(model.brief), returned \(returned) times"
    )
}

/// Working through a critique from the keyboard, and narrowing it to one
/// severity.
///
/// What it replaced: each note was answered by finding its card and pressing
/// a stamp the size of a letter, and the notes could only be read in the
/// rail's order — the highest first, which sends somebody revising up and
/// down the draft. Next and Previous go in the draft's order instead.
@MainActor
func checkWorkingThroughTheNotes() async {
    print("")
    print("Working through the notes")

    let draft = [
        "# Working through",
        "The first claim stands alone here, without any support from data or "
            + "from a source anybody could check.",
        "This second paragraph is low and slow, and it drifts along without "
            + "much of a point to make.",
        "A third paragraph is medium and muddled, mixing two ideas that each "
            + "deserve some room of their own.",
        "Finally the fourth claim repeats the first without adding evidence, "
            + "which weakens the ending.",
    ].joined(separator: "\n\n")
    let firstHigh = CritiqueFinding(
        severity: .high, category: "Evidence", location: "paragraph 1",
        quote: "The first claim stands alone here", why: "Unsupported."
    )
    let low = CritiqueFinding(
        severity: .low, category: "Voice", location: "paragraph 2",
        quote: "low and slow", why: "Flat."
    )
    let medium = CritiqueFinding(
        severity: .medium, category: "Structure", location: "paragraph 3",
        quote: "medium and muddled", why: "Two ideas at once."
    )
    let secondHigh = CritiqueFinding(
        severity: .high, category: "Logic", location: "paragraph 4",
        quote: "the fourth claim repeats the first", why: "Still unsupported."
    )
    let report = CritiqueReport(
        jobRead: "A post for developers.", overall: "Close.",
        findings: [firstHigh, low, medium, secondHigh]
    )

    let model = CritiqueModel()
    model.applyForChecking(report, for: draft)
    func opened() -> String {
        model.item(withID: model.selectedFindingID)?.finding.category ?? "nothing"
    }
    func idOf(_ finding: CritiqueFinding) -> UUID {
        model.items.first { $0.finding.quote == finding.quote }?.id ?? UUID()
    }
    func answer(_ finding: CritiqueFinding) -> CritiqueResolution? {
        model.items.first { $0.finding.quote == finding.quote }?.resolution
    }
    guard model.items.count == 4, model.items.allSatisfy(\.isAnchored) else {
        check(
            "every note is pinned to its passage",
            false,
            "\(model.items.filter(\.isAnchored).count) of \(model.items.count)"
        )
        return
    }
    let reveals = model.revealRequests
    model.selectNext()
    check(
        "Next with nothing open opens the first note in the draft, and goes to it",
        opened() == "Evidence" && model.revealRequests == reveals + 1,
        "opened \(opened()), \(model.revealRequests - reveals) reveals"
    )
    model.selectNext()
    check(
        "and the one after is the next one down the draft",
        opened() == "Voice",
        "opened \(opened())"
    )
    model.selectNext()
    model.selectNext()
    check("on to the last", opened() == "Logic", "opened \(opened())")
    model.selectNext()
    check("then round to the first again", opened() == "Evidence", "opened \(opened())")
    model.selectPrevious()
    check(
        "and Previous from the first goes round to the last",
        opened() == "Logic",
        "opened \(opened())"
    )
    model.dismiss()
    model.selectPrevious()
    check(
        "Previous behind a closed rail brings the rail back with the note open",
        model.isPresented && opened() == "Logic",
        "presented \(model.isPresented), opened \(opened())"
    )

    // A note whose passage is being rewritten has stopped asking for
    // anything, so it is not a stop on the way — but it is where the reader
    // is, so Next from it carries on from there.
    model.reveal(idOf(medium))
    model.noteCurrentText(
        draft.replacingOccurrences(of: "medium and muddled", with: "medium and clear")
    )
    check(
        "a note being rewritten is not stepped to, nor answered from the keyboard",
        model.item(withID: idOf(medium))?.isEdited == true
            && !model.steppableNotes.contains { $0.finding.category == "Structure" }
            && !model.canAnswerSelected,
        "edited \(String(describing: model.item(withID: idOf(medium))?.isEdited)), "
            + "steps through \(model.steppableNotes.map(\.finding.category))"
    )
    model.selectNext()
    check(
        "Next from it carries on down the draft instead of starting at the top",
        opened() == "Logic",
        "opened \(opened())"
    )
    model.reveal(idOf(medium))
    model.selectPrevious()
    check("and Previous from it goes back up", opened() == "Voice", "opened \(opened())")

    model.reveal(idOf(firstHigh))
    let scoreBefore = model.score
    check("the open note can be answered from the keyboard", model.canAnswerSelected)
    model.answerSelected(.completed)
    check(
        "Done marks the open note and opens the next one down the draft",
        answer(firstHigh) == .completed && opened() == "Voice",
        "\(String(describing: answer(firstHigh))), opened \(opened())"
    )
    check(
        "and moves the score as the stamp does",
        model.score > scoreBefore,
        "\(scoreBefore) -> \(model.score)"
    )
    model.answerSelected(.dismissed)
    check(
        "Dismiss does the same",
        answer(low) == .dismissed && opened() == "Logic",
        "\(String(describing: answer(low))), opened \(opened())"
    )
    model.answerSelected(.completed)
    check(
        "answering the last leaves nothing open and nothing to step to",
        model.selectedFindingID == nil && !model.canStepNotes,
        "opened \(opened()), \(model.steppableNotes.count) to step to"
    )
    model.selectNext()
    check("so Next does nothing", model.selectedFindingID == nil, "opened \(opened())")

    print("")
    print("Narrowing the notes to one severity")

    let typo = CritiqueFinding(
        severity: .low, category: "Grammar", location: "paragraph 2",
        quote: "drifts along", why: "Vague.", replacement: "wanders"
    )
    let narrowed = CritiqueModel()
    narrowed.applyForChecking(
        CritiqueReport(
            jobRead: "A post for developers.", overall: "Close.",
            findings: [firstHigh, low, medium, secondHigh, typo]
        ),
        for: draft
    )
    func noteID(_ category: String) -> UUID {
        narrowed.items.first { $0.finding.category == category }?.id ?? UUID()
    }
    let everything = narrowed.score
    narrowed.severityFilter = .high
    check(
        "narrowed to high, only the high notes are stepped through",
        narrowed.steppableNotes.map(\.finding.category) == ["Evidence", "Logic"],
        "steps through \(narrowed.steppableNotes.map(\.finding.category))"
    )
    check(
        "and only their passages are shaded",
        Set(narrowed.highlights.map(\.id)) == [noteID("Evidence"), noteID("Logic")],
        "\(narrowed.highlights.count) passages shaded"
    )
    check(
        "while the score still counts every note",
        narrowed.score == everything && narrowed.outstanding.count == 5,
        "\(everything) -> \(narrowed.score), \(narrowed.outstanding.count) outstanding"
    )
    narrowed.reveal(noteID("Logic"))
    narrowed.selectNext()
    check(
        "and Next goes round the notes it shows",
        narrowed.selectedFindingID == noteID("Evidence"),
        "opened \(String(describing: narrowed.item(withID: narrowed.selectedFindingID)?.finding.category))"
    )

    narrowed.severityFilter = nil
    narrowed.reveal(noteID("Voice"))
    narrowed.hover(noteID("Structure"))
    narrowed.severityFilter = .high
    check(
        "narrowing closes a note it hides, and lets go of the one under the pointer",
        narrowed.selectedFindingID == nil && narrowed.hoveredFindingID == nil,
        "open \(String(describing: narrowed.selectedFindingID)), "
            + "hovered \(String(describing: narrowed.hoveredFindingID))"
    )
    narrowed.severityFilter = nil
    narrowed.reveal(noteID("Evidence"))
    narrowed.severityFilter = .high
    check(
        "but leaves open a note it still shows",
        narrowed.selectedFindingID == noteID("Evidence")
    )

    narrowed.severityFilter = nil
    narrowed.reveal(noteID("Grammar"))
    check("Apply is offered for the open note's suggestion", narrowed.canApplySelected)
    narrowed.reveal(noteID("Voice"))
    check(
        "and not for a note without one",
        narrowed.canAnswerSelected && !narrowed.canApplySelected
    )

    narrowed.severityFilter = .medium
    narrowed.noteCurrentText(draft + "\n\nOne more line at the end.")
    check("typing leaves the narrowing alone", narrowed.severityFilter == .medium)
    narrowed.show(revision: narrowed.history.latest?.id)
    check(
        "putting a critique on screen shows every note again",
        narrowed.history.latest != nil && narrowed.severityFilter == nil,
        "\(narrowed.history.revisions.count) critiques kept, "
            + "filter \(String(describing: narrowed.severityFilter))"
    )
    narrowed.severityFilter = .low
    narrowed.attach(
        to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("narrowed-\(UUID().uuidString).md"),
        text: draft
    )
    check(
        "and so does opening another document",
        narrowed.severityFilter == nil,
        "filter \(String(describing: narrowed.severityFilter))"
    )

    let held = HeldCritique()
    let running = CritiqueModel(service: held)
    running.applyForChecking(report, for: draft)
    running.severityFilter = .high
    running.request(on: draft + "\n\nA new closing line for this run.", documentURL: nil)
    await settle { held.isWaiting }
    check(
        "and so does running a critique, whose rail has no strip to undo it from",
        running.isRunning && running.severityFilter == nil,
        "running \(running.isRunning), filter \(String(describing: running.severityFilter))"
    )

    // The one time the rail and the draft disagree about the order: a run's
    // new notes sit above the old ones until it lands, and a Next that
    // followed the rail would jump from the middle of the draft to the top.
    let arrival = CritiqueFinding(
        severity: .medium, category: "Pacing", location: "paragraph 3",
        quote: "deserve some room of their own", why: "Which two?"
    )
    held.report(CritiqueProgress(stage: .writing, findingsSoFar: 1, findings: [arrival]))
    await settle { !running.arriving.isEmpty }
    func runningOpened() -> String {
        running.item(withID: running.selectedFindingID)?.finding.category ?? "nothing"
    }
    running.reveal(running.items.first { $0.finding.category == "Structure" }?.id ?? UUID())
    running.selectNext()
    check(
        "a note still arriving sits above the rest, but Next reaches it where its passage is",
        running.arriving.map(\.finding.category) == ["Pacing"] && runningOpened() == "Pacing",
        "\(running.arriving.count) arriving, opened \(runningOpened())"
    )
    check(
        "though it cannot be answered from the keyboard until the run lands",
        !running.canAnswerSelected
    )
    running.selectNext()
    check(
        "and Next from it goes on down the draft",
        runningOpened() == "Logic",
        "opened \(runningOpened())"
    )
    held.answer(CritiqueReport(jobRead: "A post for developers.", overall: "Close.", findings: []))
    await settle { !running.isRunning }
}

/// More than two notes to a screen.
///
/// What it replaced, measured on the friction pass: a real critique's summary
/// filled the first screen of the rail, and under it the notes fitted about
/// two and a half to a 900-point window. A compact note is its heading and
/// the first line of its comment until it is opened, and the summary's two
/// lists wait to be asked for.
@MainActor
func checkTheRailFitsTheNotes() {
    print("")
    print("Fitting the notes to a screen")

    let theme = EditorColorTheme(color: .blue, mode: .light)
    let restoreHand = pinDefault(CritiqueHand.storageKey, to: CritiqueHand.sans.rawValue)
    let restoreSummary = pinDefault(CritiqueSidebar.summaryExpandedKey, to: false)
    let restoreDensity = pinDefault(CritiqueSidebar.compactNotesKey, to: false)
    defer {
        restoreHand()
        restoreSummary()
        restoreDensity()
    }

    // One note, both ways, at the width the rail gives a note.
    let wordy = CritiqueFinding(
        severity: .high, category: "Logic and credibility", needsVerification: true,
        location: "Opening, paragraph 2", quote: "the sentence in question",
        why: "This note says enough that it runs to a second and a third line "
            + "at the rail's width, as most of a real critique's notes do.",
        fix: "Put the point first, and the qualification after it."
    )
    func cardHeight(compact: Bool) -> CGFloat {
        let host = NSHostingView(rootView: CritiqueCard(
            item: CritiqueModel.Item(finding: wordy, range: NSRange(location: 0, length: 4)),
            colorTheme: theme,
            isSelected: false,
            onTap: {},
            onHoverChange: { _ in },
            onResolve: { _ in },
            isCompact: compact
        ).frame(width: 316))
        return host.fittingSize.height
    }
    let fullHeight = cardHeight(compact: false)
    let compactHeight = cardHeight(compact: true)
    check(
        "a compact note takes under half the height of the same note in full",
        compactHeight > 0 && compactHeight * 2 < fullHeight,
        "\(Int(compactHeight))pt against \(Int(fullHeight))pt"
    )

    let categories = [
        "Evidence", "Pacing", "Voice", "Structure", "Clarity", "Rhythm", "Grammar", "Endings",
    ]
    var paragraphs: [String] = []
    var findings: [CritiqueFinding] = []
    for (index, category) in categories.enumerated() {
        let quote = "paragraph number \(index + 1) says something"
        paragraphs.append("This \(quote) that a reader would want to see shown with an example.")
        findings.append(CritiqueFinding(
            severity: index < 3 ? .high : (index < 6 ? .medium : .low),
            category: category, location: "paragraph \(index + 1)",
            quote: quote,
            why: "This note says enough that it runs to a second and a third line "
                + "at the rail's width.",
            fix: "Show it with an example from the team's own builds."
        ))
    }
    let model = CritiqueModel()
    model.applyForChecking(
        CritiqueReport(
            jobRead: "A post for developers.",
            overall: "A clear argument that needs one worked example and a firmer "
                + "close before it goes out.",
            whatWorks: [
                "The opening names the problem in its first line.",
                "Each section makes one point.",
                "It sounds like a person talking.",
            ],
            whatDoesNotWork: [
                "Nothing is shown, only told.",
                "The close repeats the opening.",
                "Two claims have no source.",
            ],
            findings: findings
        ),
        for: paragraphs.joined(separator: "\n\n")
    )

    /// The rail as a 700-point window shows it, read back from its pixels.
    func drawnRail(_ name: String) -> String {
        let host = NSHostingView(rootView: CritiqueSidebar(
            critique: model, colorTheme: theme, isStale: false,
            onRerun: {}, onRerunChanges: {}
        ))
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        if let path = ProcessInfo.processInfo.environment["MDE_DENSE_PNG"],
           let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = path.replacingOccurrences(of: ".png", with: "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: file))
            print("  wrote \(file)")
        }
        return readable(recognisedText(in: host).joined(separator: " "))
    }
    func notesShown(in drawn: String) -> [String] {
        categories.filter { legible($0, in: drawn) }
    }

    let inFull = drawnRail("full")
    check(
        "with the summary closed, the first note is on the first screen",
        legible("Evidence", in: inFull),
        "read \"\(inFull.prefix(500))\""
    )
    check(
        "and the strip counts what is still open at each severity",
        legible("3 high", in: inFull) && legible("3 medium", in: inFull)
            && legible("2 low", in: inFull),
        "read \"\(inFull.prefix(300))\""
    )

    UserDefaults.standard.set(true, forKey: CritiqueSidebar.compactNotesKey)
    let inCompact = drawnRail("compact")
    let fullCount = notesShown(in: inFull).count
    let compactCount = notesShown(in: inCompact).count
    check(
        "compact notes fit at least twice as many to the same screen",
        compactCount >= 2 * max(1, fullCount) && compactCount >= 5,
        "\(compactCount) compact (\(notesShown(in: inCompact))) against \(fullCount) in full"
    )
    check(
        "and a compact note keeps its advice to itself",
        !legible("Show it with an example", in: inCompact),
        "read \"\(inCompact.prefix(500))\""
    )
    model.reveal(model.items.first { $0.finding.category == "Pacing" }?.id ?? UUID())
    let withOneOpen = drawnRail("open")
    check(
        "until it is the open note, which is always in full",
        legible("Show it with an example", in: withOneOpen),
        "read \"\(withOneOpen.prefix(500))\""
    )

    model.severityFilter = .low
    let lows = drawnRail("low")
    check(
        "narrowed to low, the rail shows only the low notes",
        notesShown(in: lows) == ["Grammar", "Endings"],
        "it shows \(notesShown(in: lows))"
    )
    for item in model.items where item.finding.severity == .low {
        model.setResolution(.completed, for: item.id)
    }
    let none = drawnRail("exhausted")
    check(
        "and once they are answered it says so, with the way back beside it",
        legible("No open low notes left.", in: none) && legible("Show all", in: none),
        "read \"\(none.prefix(500))\""
    )

    // The empty rail is where the keys are learned: the menu that holds them
    // is not somewhere anybody reads before they need it.
    let storedProvider = UserDefaults.standard.string(forKey: CritiqueProvider.storageKey)
    CritiqueCredentials.provider = .copilotCLI
    defer {
        if let storedProvider {
            UserDefaults.standard.set(storedProvider, forKey: CritiqueProvider.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CritiqueProvider.storageKey)
        }
    }
    let unread = CritiqueModel()
    let emptyHost = NSHostingView(rootView: CritiqueSidebar(
        critique: unread, colorTheme: theme, isStale: false,
        onRerun: {}, onRerunChanges: {}, onQuickPass: {}
    ))
    emptyHost.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
    let emptyWindow = NSWindow(
        contentRect: emptyHost.frame, styleMask: [.borderless],
        backing: .buffered, defer: false
    )
    emptyWindow.contentView = emptyHost
    emptyWindow.orderBack(nil)
    emptyHost.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    emptyHost.layoutSubtreeIfNeeded()
    let empty = readable(recognisedText(in: emptyHost).joined(separator: " "))
    emptyWindow.orderOut(nil)
    check(
        "an empty rail says what a critique does, and lists the keys that drive it",
        legible("pins a note to each passage", in: empty)
            && legible("Next note, previous note", in: empty)
            && legible("Show or hide this rail", in: empty),
        "read \"\(empty.prefix(500))\""
    )

    print("")
    print("The summary's switch")
    for (works, doesNot, isOpen, expected) in [
        (0, 0, false, nil),
        (0, 0, true, nil),
        (2, 0, false, "What works (2)"),
        (0, 3, false, "What doesn't work (3)"),
        (2, 3, false, "What works (2) and what doesn't (3)"),
        (2, 3, true, "Show less"),
    ] as [(Int, Int, Bool, String?)] {
        let said = CritiqueSidebar.summaryDisclosure(
            works: works, doesNotWork: doesNot, isExpanded: isOpen
        )
        check(
            "\(works) and \(doesNot), \(isOpen ? "open" : "closed"): "
                + (expected.map { "\"\($0)\"" } ?? "no switch"),
            said == expected,
            "it says \(said ?? "nothing")"
        )
    }
}

/// Every way of working through the notes is in the Critique menu, on a key
/// the text view does not already use.
///
/// Read from the source rather than from a running menu bar, which this
/// checker does not have. What matters is that the keys are the ones the
/// rail's empty state and its tooltips promise.
@MainActor
func checkTheCritiqueMenu() {
    print("")
    print("The Critique menu")

    let commands = (try? String(
        contentsOfFile: "Sources/MarkdownEditor/MarkdownEditorCommands.swift",
        encoding: .utf8
    )) ?? ""
    guard let menuStart = commands.range(of: "CommandMenu(\"Critique\")") else {
        check("there is a Critique menu", false)
        return
    }
    let menu = String(commands[menuStart.lowerBound...])
    let before = String(commands[..<menuStart.lowerBound])
    check(
        "running a critique moved out of the Markdown menu into it",
        menu.contains("Button(\"AI Assisted Critique\")")
            && menu.contains("Button(\"Quick Critique Pass\")")
            && !before.contains("AI Assisted Critique"),
        "the Markdown menu still lists it"
    )
    for (title, keys, shortcut) in [
        ("Next Note", "⌥⌘↓", ".keyboardShortcut(.downArrow, modifiers: [.option, .command])"),
        ("Previous Note", "⌥⌘↑", ".keyboardShortcut(.upArrow, modifiers: [.option, .command])"),
        ("Mark Note Done", "⌥⌘↩", ".keyboardShortcut(.return, modifiers: [.option, .command])"),
        ("Dismiss Note", "⌥⌘⌫", ".keyboardShortcut(.delete, modifiers: [.option, .command])"),
        ("Apply Suggestion", "⇧⌥⌘↩",
         ".keyboardShortcut(.return, modifiers: [.shift, .option, .command])"),
    ] {
        let at = menu.range(of: "Button(\"\(title)\")")
        let follows = at.map { menu[$0.upperBound...].prefix(160).contains(shortcut) } ?? false
        check("\(title) is in it, on \(keys)", follows)
        // The keys the empty rail teaches are the keys the menu has.
        check(
            "and the empty rail teaches \(keys)",
            CritiqueSidebar.keyList.contains { $0.keys.contains(keys) },
            "the rail lists \(CritiqueSidebar.keyList.map(\.keys))"
        )
    }
    check(
        "and so is the compact switch",
        menu.contains("Toggle(\"Compact Notes\", isOn: $compactNotes)")
    )
    check(
        "the rail can be shown and hidden from the View menu, on ⌃⌘I",
        before.contains("\"Show Critique\" : \"Hide Critique\"")
            && before.contains(".keyboardShortcut(\"i\", modifiers: [.control, .command])"),
        "no Show/Hide Critique on ⌃⌘I"
    )
    // ⌘⌫ deletes to the start of the line in every Mac text view. A menu key
    // wins over the text view, so taking it would have cost the writer that.
    check(
        "no note command takes a key the text view already uses",
        !menu.contains("modifiers: .command)") && !menu.contains(".delete)")
            && !menu.contains("modifiers: [.command])"),
        "a note command is on ⌘ alone"
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

/// Re-reading only what changed has to keep the notes about everything else.
///
/// The failure this exists to catch is silent and looks like good news: a
/// partial re-run that drops the notes it was told not to re-examine leaves a
/// rail with fewer criticisms in it, which reads exactly like a draft that got
/// better. Nothing on screen says the notes were deleted rather than fixed.
@MainActor
func checkPartialCritiqueKeepsTheOtherNotes() {
    print("")
    print("Critiquing only what changed")

    let before = """
    # Caching

    Studies show that caching improves performance by 90%.

    The tradeoff is staleness.
    """

    let model = CritiqueModel()
    let stale = CritiqueFinding(
        severity: .high, category: "Logic and credibility",
        location: "paragraph 2",
        quote: "Studies show that caching improves performance by 90%.",
        why: "No citation."
    )
    model.applyForChecking(
        CritiqueReport(
            jobRead: "a developer", overall: "needs sources", findings: [stale]
        ),
        for: before
    )
    check(
        "the first critique anchored its note",
        model.items.count == 1 && model.items[0].range != nil,
        "\(model.items.count) items, range \(String(describing: model.items.first?.range))"
    )

    // A new paragraph at the end: the old note is nowhere near it.
    // The trailing newline matters and is not decoration: every real file ends
    // with one, and appending after it is what broke. The insertion then
    // carries the blank line with it, and widening to paragraph boundaries
    // started inside the *previous* paragraph's trailing newline and swallowed
    // it — retiring a note about a sentence nobody had touched. Checked here
    // rather than only in the unit tests because this is the shape a document
    // on disk actually has.
    let after = before + "\n" + "\nCache invalidation is genuinely the hard part.\n"
    // What the editor does on every keystroke. Without it the model has not
    // been told the draft moved, and this check would be asking about a state
    // the app is never in.
    model.noteCurrentText(after)
    let changed = CritiqueChangeScope.changedParagraphs(from: before, to: after)
    guard let changed else {
        check("the edit was detected", false, "no change found")
        return
    }
    check(
        "the changed passage is the new paragraph only",
        CritiqueChangeScope.passage(changed, in: after)
            == "Cache invalidation is genuinely the hard part.",
        "passage: \(CritiqueChangeScope.passage(changed, in: after))"
    )
    check(
        "and that is what the model would default to reading",
        model.canCritiqueChangesOnly,
        "it would re-read the whole draft instead"
    )

    let fresh = CritiqueFinding(
        severity: .medium, category: "Clarity and precision",
        location: "paragraph 4",
        quote: "Cache invalidation is genuinely the hard part.",
        why: "Asserted without saying why."
    )
    model.applyChangesForChecking(
        CritiqueReport(
            jobRead: "a developer", overall: "still needs sources", findings: [fresh]
        ),
        for: after,
        changed: changed
    )

    check(
        "the untouched note survived the partial re-run",
        model.items.contains { $0.finding.quote == stale.quote },
        "it was dropped — the rail now shows \(model.items.count) notes"
    )
    check(
        "the new paragraph's note was added",
        model.items.contains { $0.finding.quote == fresh.quote },
        "the new finding is missing"
    )
    check(
        "and the surviving note still points at its sentence",
        model.items.first { $0.finding.quote == stale.quote }?.range != nil,
        "it lost its anchor"
    )

    // The stored revision has to carry both, or reopening the document later
    // shows only what the last partial run happened to look at.
    check(
        "the saved revision carries the whole rail, not just this run",
        model.report?.findings.count == 2,
        "the report holds \(model.report?.findings.count ?? -1) findings"
    )

    // Rewriting the criticised sentence must supersede its note rather than
    // leaving a criticism of text that is gone. In two steps: the rewrite
    // stops the note counting at once, and the critique that reads the new
    // sentence is what says the problem has gone.
    let rewritten = after.replacingOccurrences(
        of: "Studies show that caching improves performance by 90%.",
        with: "Caching cut our median response time from 400ms to 20ms."
    )
    model.noteCurrentText(rewritten)
    let edited = model.items.first { $0.finding.quote == stale.quote }
    check(
        "rewriting a criticised sentence marks its note edited, not fixed",
        edited?.isEdited == true && edited?.isFixed == false,
        "edited \(String(describing: edited?.isEdited)), "
            + "fixed \(String(describing: edited?.isFixed))"
    )
    check(
        "and it stops counting against the score straight away",
        !model.outstanding.contains { $0.finding.quote == stale.quote },
        "the rewritten sentence's note is still outstanding"
    )
    guard let secondChange = CritiqueChangeScope.changedParagraphs(
        from: after, to: rewritten
    ) else {
        check("the rewrite was detected", false, "no change found")
        return
    }
    model.applyChangesForChecking(
        CritiqueReport(
            jobRead: "a developer", overall: "better", findings: []
        ),
        for: rewritten,
        changed: secondChange
    )
    // Shown the rewritten note and silent about it: the critic has read the
    // new sentence and has nothing to say. That retires it — as Fixed, kept
    // at the foot of the rail for this run so the author can see what the
    // rewrite bought, and out of the report so it does not come back.
    let retired = model.items.first { $0.finding.quote == stale.quote }
    check(
        "a critique that reads the rewrite and says nothing retires its note as fixed",
        retired?.isFixed == true
            && !(model.report?.findings.contains { $0.quote == stale.quote } ?? true)
            && !model.outstanding.contains { $0.finding.quote == stale.quote },
        "fixed \(String(describing: retired?.isFixed)), "
            + "\(model.report?.findings.count ?? -1) findings in the report"
    )
    check(
        "and the rail says so",
        model.lastChange == CritiqueCarry.Delta(fixed: 1, reopened: 0, new: 0),
        "the change reads \(String(describing: model.lastChange))"
    )
    check(
        "while the note about the untouched paragraph stays",
        model.items.contains { $0.finding.quote == fresh.quote && $0.isOutstanding },
        "an unrelated note was dropped by a rewrite elsewhere"
    )
}


/// The skill's version, read from the copy actually installed on this machine.
///
/// The unit tests cover the parsing against fixed strings. This is the other
/// half: that the strings the tests assume are the strings git really produces
/// here, and that the path the app looks in is where the skill really is. A
/// format that changed under us would pass every unit test and show "Reading…"
/// for ever.
@MainActor
func checkTheKonvoSkillIsReported() async {
    print("")
    print("The konvo skill's version")

    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(KonvoSkill.relativePath)
    // A machine without the Copilot CLI has no skills directory at all, and
    // skipping there is honest. A skills directory *without* konvo in it is a
    // different thing: either the skill is genuinely absent, or the path this
    // app looks in is wrong — and a wrong path would otherwise skip the whole
    // check silently, which is how a typo ships.
    let skillsRoot = directory.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: skillsRoot.path) else {
        print("  ..   no Copilot skills directory on this machine, so there is "
            + "nothing to read")
        return
    }
    let installedSkills = (try? FileManager.default.contentsOfDirectory(
        atPath: skillsRoot.path
    )) ?? []
    guard installedSkills.contains(where: {
        $0.caseInsensitiveCompare("konvo") == .orderedSame
    }) else {
        print("  ..   konvo is not among the installed skills "
            + "(\(installedSkills.sorted().joined(separator: ", ")))")
        return
    }
    check(
        "the path the app looks in is the one the skill is installed at",
        FileManager.default.fileExists(atPath: directory.path),
        "konvo is in \(skillsRoot.path) but the app looks at \(directory.path)"
    )
    check(
        "the app looks where the skill actually is",
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("SKILL.md").path
        ),
        "no SKILL.md at \(directory.path)"
    )

    let model = KonvoSkillModel()
    model.read()
    // Polled rather than slept through: a fixed wait is either too short on a
    // slow machine or wasted on a fast one.
    for _ in 0..<60 {
        if case .reading = model.state {} else if case .unread = model.state {} else { break }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    switch model.state {
    case .installed(let installed):
        check(
            "it reports a commit",
            installed.commit.count >= 7,
            "got '\(installed.commit)'"
        )
        check(
            "and a date",
            installed.date != nil,
            "the date did not parse — git's --format=%cI output has changed"
        )
        check(
            "and says so in one line",
            !KonvoSkill.summary(for: installed).isEmpty,
            "the summary is empty"
        )
        print("       \(KonvoSkill.summary(for: installed)) — \(installed.subject)")

        // The UI talks about the critique, not about the plumbing.
        //
        // Which tool carries the request is an implementation detail, and the
        // skill is sent with every request now, so naming a CLI or a vendor in
        // a label tells the reader nothing they can act on and dates the app to
        // whatever it happened to shell out to.
        //
        // Checked against the string literals in the views and the provider,
        // which is where labels live. The comments are exempt — this file's own
        // reasoning is full of these words on purpose.
        let forbidden = ["Copilot CLI", "GitHub Copilot", "npm install", "@github/copilot"]
        for file in [
            "Sources/MarkdownEditor/CritiqueSettingsView.swift",
            "Sources/MarkdownEditor/CritiqueSidebar.swift",
            "Sources/MarkdownEditor/CritiqueService.swift",
            "../Shared/Sources/MarkdownEditorCore/CritiqueProvider.swift",
            "../Shared/Sources/MarkdownEditorCore/CritiqueProgress.swift",
        ] {
            let source = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            // Literals only: every run of text between double quotes, with the
            // comment lines dropped first.
            let code = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            let literals = code.split(separator: "\"")
                .enumerated()
                .filter { $0.offset % 2 == 1 }
                .map { String($0.element) }
                .joined(separator: " ")
            for word in forbidden {
                check(
                    "\((file as NSString).lastPathComponent) does not put "
                        + "\"\(word)\" on screen",
                    !literals.contains(word),
                    "a label still names the tool"
                )
            }
        }

        // The skill is not just reported, it is used.
        //
        // The prompt used to *name* the skill and hope the thing answering had
        // it — true for one provider and false for the rest, so the same draft
        // got a KONVO critique or a generic one depending on a setting nobody
        // would connect to it. It is sent now, and this is the check that it
        // really comes off this machine's disk and into the request.
        let pass = CritiqueService.loadedSkillPass()
        check(
            "the installed skill's critique pass can be read",
            pass != nil,
            "SKILL.md has no '\(KonvoSkill.critiqueHeading)' section"
        )
        if let pass {
            check(
                "and it is the critique pass rather than the whole file",
                pass.count > 2_000 && pass.count < 60_000,
                "\(pass.count) characters — the whole file is about 110,000"
            )
            let prompt = CritiqueRequest.prompt(
                forDocument: "A draft.", skill: pass
            )
            check(
                "and it reaches the request the model is sent",
                prompt.contains(pass),
                "the prompt does not carry the pass"
            )
        }

        // And it reaches the screen. A version read into a model that never
        // draws is a version nobody can see, which is the whole point of it.
        let settings = NSHostingView(rootView: AnyView(CritiqueSettingsView()))
        settings.frame = NSRect(x: 0, y: 0, width: 460, height: 900)
        settings.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        settings.layoutSubtreeIfNeeded()
        let labels = accessibleStrings(in: settings)
        check(
            "the settings window draws the version it read",
            labels.contains { $0.contains(installed.commit) },
            "the commit is not on screen; it shows: "
                + "\(labels.prefix(24).joined(separator: " | "))"
        )
        // The section heading and the button are SwiftUI's own drawing rather
        // than AppKit controls, so the walk above cannot see them — it finds
        // the version only because the version is selectable text, whose
        // string SwiftUI hands to a view. Checked in the source instead, which
        // is weaker but honest, and paired with the unit tests that cover what
        // pressing it does.
        let settingsSource = (try? String(
            contentsOfFile: "Sources/MarkdownEditor/CritiqueSettingsView.swift",
            encoding: .utf8
        )) ?? ""
        check(
            "settings has a KONVO Skill section",
            settingsSource.contains("Section(\"KONVO Skill\")"),
            "no such section"
        )
        check(
            "with an Update button wired to the pull",
            settingsSource.contains("Button(\"Update\") { skill.update() }"),
            "the Update button is missing or wired elsewhere"
        )
        check(
            "that is disabled when there is nothing to update",
            settingsSource.contains("skill.isUpdating || !canUpdateSkill"),
            "the button is offered even when it cannot work"
        )
        // And the rail's header opens all of this, which is the ask: the key
        // and the model were reachable only from the app's Settings menu or
        // from the rail's first-run state.
        let railSource = (try? String(
            contentsOfFile: "Sources/MarkdownEditor/CritiqueSidebar.swift",
            encoding: .utf8
        )) ?? ""
        if let at = railSource.range(of: "Image(systemName: \"gearshape\")") {
            let around = railSource[
                railSource.index(at.lowerBound, offsetBy: -260)..<at.upperBound
            ]
            check(
                "the rail's header has a settings control that opens settings",
                around.contains("openSettings()"),
                "the gear is there but does not open settings"
            )
        } else {
            check(
                "the rail's header has a settings control",
                false,
                "no gear in the header"
            )
        }
    case .missing(let absence):
        check(
            "the installed skill can be read",
            false,
            absence.summary
        )
    case .reading, .unread:
        check("reading the skill finishes", false, "still reading after 3s")
    }
}


/// Every label a rendered SwiftUI view exposes to a reader in this process.
///
/// Button titles, text fields, and the strings behind selectable text. That is
/// less than it sounds: on macOS 27 a `Form` no longer puts its values in real
/// text fields, and words drawn unselectable are in no view at all — the rail
/// is checked from its drawing, through `recognisedText(in:)`, for that reason.
@MainActor
func accessibleStrings(in view: NSView) -> [String] {
    var found: [String] = []
    func walk(_ node: Any, _ depth: Int) {
        guard depth < 30 else { return }
        if let v = node as? NSView {
            // Concrete types only. Reading arbitrary objects through KVC
            // raises `NSUnknownKeyException` on the first one that does not
            // have the key, which aborted the whole run.
            if let button = v as? NSButton, !button.title.isEmpty {
                found.append(button.title)
            }
            if let field = v as? NSTextField, !field.stringValue.isEmpty {
                found.append(field.stringValue)
            }
            // Selectable text. SwiftUI draws it itself and hands the string
            // to the view beneath its text-interaction view as that view's
            // accessibility value, which on macOS 27 is the only place the
            // settings' version can be read from in this process.
            if let value = v.accessibilityValue() as? String, !value.isEmpty {
                found.append(value)
            }
            for child in v.subviews { walk(child, depth + 1) }
        }
    }
    walk(view, 0)
    return found
}

/// The lines of text legible in a view's drawing, top to bottom.
///
/// For words SwiftUI draws itself with nothing in AppKit's tree holding them.
/// The accessibility tree would, but SwiftUI builds it only once an assistive
/// client connects, and in this process none has: an `NSHostingView` answers
/// `accessibilityChildren()` with nothing at all.
///
/// Drawn at twice the view's size on whatever screen this runs on, and onto
/// white, so the recogniser never meets a transparent background. The first
/// call on a machine loads the recogniser, which can take half a minute;
/// later ones take a fraction of a second.
@MainActor
func recognisedText(in view: NSView) -> [String] {
    let size = view.bounds.size
    guard size.width > 0, size.height > 0,
          let rep = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
          )
    else { return [] }
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let drawn = rep.cgImage,
          let context = CGContext(
              data: nil, width: drawn.width, height: drawn.height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
    else { return [] }
    let whole = CGRect(x: 0, y: 0, width: drawn.width, height: drawn.height)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(whole)
    context.draw(drawn, in: whole)
    guard let image = context.makeImage() else { return [] }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Correction would "fix" the words being looked for into words that are
    // not on the page, and a check has to read what is there.
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    } catch {
        print("  (the drawing could not be read: \(error.localizedDescription))")
        return []
    }
    // Vision measures from the bottom-left corner, so the top line has the
    // largest y.
    return (request.results ?? [])
        .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        .compactMap { $0.topCandidates(1).first?.string }
}

/// Sets a preference for the length of a check, and returns what puts it
/// back.
///
/// The rail reads its switches from the same defaults the app keeps them in,
/// so a check that drew it compact and left it so would be a rail somebody
/// next opens compact without having asked for it.
func pinDefault(_ key: String, to value: Any) -> () -> Void {
    let stored = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(value, forKey: key)
    return {
        if let stored {
            UserDefaults.standard.set(stored, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

/// Text reduced to what reading it back can be trusted with: lower case, and
/// every run of spacing one space, so a phrase the rail wrapped across two
/// lines is still found.
func readable(_ text: String) -> String {
    text.lowercased()
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

/// Whether a phrase can be made out in a drawing read back by `readable`.
///
/// Word for word, except that one stray mark of a character or two may sit
/// between any two of its words. Lines are put in order by height, and an
/// icon beside a phrase the rail wrapped is read as a character of its own:
/// the ↩ at the foot of an answered note came back as "5", and on a card
/// whose jitter tilted it the wrong way that "5" sorted between "critique"
/// and "checks it." — failing one run in three over a rail that read
/// perfectly well. A word in the way, rather than a mark, still fails.
func legible(_ phrase: String, in drawn: String) -> Bool {
    let words = readable(phrase).split(separator: " ")
    let read = drawn.split(separator: " ")
    guard let first = words.first else { return true }
    search: for start in read.indices where read[start] == first {
        var at = start
        for word in words.dropFirst() {
            at += 1
            if at < read.count, read[at] != word, read[at].count <= 2 { at += 1 }
            guard at < read.count, read[at] == word else { continue search }
        }
        return true
    }
    return false
}
