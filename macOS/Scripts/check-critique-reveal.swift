// Does clicking a note actually take you to the passage — on the first click?
//
// The feature's whole interaction is "click the comment, land on the
// sentence". It was reported as needing several clicks, and every unit test of
// the anchoring passed while it did: what breaks is not the arithmetic but
// AppKit. `scrollRangeToVisible` reads the layout that exists at the moment it
// is called, and the clip view clamps the offset to the text view's *frame*,
// which grows only as far as the document has been laid out.
//
// The state that matters is a pane whose layout has just been thrown away.
// Re-styling replaces the whole text storage on every edit, and the editor
// deliberately lays out only as far as the restored viewport afterwards —
// measuring a long document per keystroke is felt as typing lag. So a pane a
// reader has just typed into has measured about a screenful, and a passage
// 280,000 points down is scrolled to against a frame 1,000 points tall.
//
// A pane that has been sitting still instead is useless for this: AppKit lays
// the rest out in the background and never shrinks a frame once grown, so the
// check passes whatever the code does. That trap is what made the first
// version of this file worthless.
//
// The window it opens is placed far off-screen and never ordered front.
//
// Built by Scripts/run-critique-reveal-checks.sh against the real app sources.

import AppKit
import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

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

@MainActor
func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
func firstTextView(under root: NSView) -> RichMarkdownTextView? {
    descendants(of: root).compactMap { $0 as? RichMarkdownTextView }.first
}

/// A draft long enough that the passages at the end are nowhere near the part
/// a re-styled pane has measured.
func longDraft(paragraphs: Int) -> String {
    var lines: [String] = ["# A long draft", ""]
    for index in 0..<paragraphs {
        lines.append(
            "Paragraph \(index) carries enough ordinary prose to wrap across "
                + "more than one line in the column the editor sets, which is "
                + "what makes the document tall enough to be worth scrolling."
        )
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

@main
@MainActor
enum Harness {
    static var draft = ""
    static var hosting: NSHostingView<RichTextEditor>?
    static var session: MarkdownEditorSession?
    static var critique = CritiqueModel()

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let paragraphs = 1200
        draft = longDraft(paragraphs: paragraphs)

        func quote(paragraph: Int) -> String {
            "Paragraph \(paragraph) carries enough ordinary prose to wrap across"
        }
        let middle = CritiqueFinding(
            severity: .medium,
            category: "Middle",
            location: "Middle",
            quote: quote(paragraph: paragraphs / 2),
            why: "Halfway down, well past what a re-styled pane has measured."
        )
        let far = CritiqueFinding(
            severity: .high,
            category: "Ending",
            location: "Ending",
            quote: quote(paragraph: paragraphs - 3),
            why: "The passage the reported bug was about."
        )
        let report = CritiqueReport(
            jobRead: "A long draft, for checking the reveal.",
            overall: "Long.",
            findings: [middle, far]
        )

        session = MarkdownEditorSession(fileURL: nil, initialText: draft)
        critique.applyForChecking(report, for: draft)

        let frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let hosting = NSHostingView(rootView: editor())
        Self.hosting = hosting
        hosting.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        window.orderBack(nil)

        settle(for: 1.0)
        hosting.layoutSubtreeIfNeeded()
        settle(for: 0.5)

        guard let textView = firstTextView(under: hosting),
            let scrollView = textView.enclosingScrollView
        else {
            print("  FAIL the rendered pane never appeared in the hierarchy")
            exit(1)
        }

        print("Clicking a note reveals its passage")

        check(
            "every finding anchored to the draft",
            critique.items.allSatisfy(\.isAnchored),
            "anchored \(critique.items.filter(\.isAnchored).count) of "
                + "\(critique.items.count)"
        )

        for (label, finding) in [("middle", middle), ("far", far)] {
            // The state the bug lives in: a reader has just typed, so the
            // pane's layout was thrown away and rebuilt only as far as the
            // screenful they are looking at.
            reStyleAfterAnEdit(scrollView: scrollView)
            let measured = textView.frame.height

            // One click.
            critique.selectedFindingID = finding.id
            settle(for: 0.5)

            let boxes = textView.critiqueHighlightBoxes(
                for: renderedRange(of: finding, in: textView)
            )
            let visible = scrollView.documentVisibleRect
            check(
                "one click reveals the \(label) passage",
                boxes.contains { visible.intersects($0) },
                boxes.isEmpty
                    ? "the passage has no drawn box at all"
                    : "passage at y \(Int(boxes[0].minY)), viewport "
                        + "\(Int(visible.minY))…\(Int(visible.maxY)); the pane "
                        + "had measured \(Int(measured))pt when it was asked"
            )
            // And *framed*, by the rule the shared arithmetic states rather
            // than by whatever the platform's own reveal happens to do — that
            // one does the smallest scroll that makes a rectangle visible,
            // which leaves a passage that was below the fold hard against the
            // bottom edge with nothing after it to read.
            if let passage = passageRect(of: finding, in: textView) {
                let settled = EditorScrollGeometry(
                    documentHeight: textView.frame.height,
                    viewportHeight: scrollView.contentView.bounds.height,
                    offset: scrollView.contentView.bounds.minY
                )
                let wanted = settled.offset(
                    toReveal: (minY: passage.minY, height: passage.height)
                )
                check(
                    "and frames the \(label) passage where the shared "
                        + "arithmetic says",
                    abs(settled.offset - wanted) < 2,
                    "landed at \(Int(settled.offset)), wanted \(Int(wanted))"
                )
            }
            critique.selectedFindingID = nil
            settle(for: 0.2)
        }

        // Asking for a passage that is already selected should take you back
        // to it. Somebody pressing a card twice is asking to be taken there
        // again, not to undo the selection.
        critique.selectedFindingID = far.id
        settle(for: 0.5)
        reStyleAfterAnEdit(scrollView: scrollView)
        // Through the same decision the rail's press makes, not around it: a
        // check that calls `reveal` directly passes against the toggle this
        // replaced.
        critique.press(critique.item(withID: far.id)!)
        settle(for: 0.5)
        let boxes = textView.critiqueHighlightBoxes(
            for: renderedRange(of: far, in: textView)
        )
        let visible = scrollView.documentVisibleRect
        check(
            "asking again for the passage already selected reveals it again",
            boxes.contains { visible.intersects($0) },
            "viewport back at \(Int(visible.minY))"
        )
        check(
            "and the selection survives being asked again",
            critique.selectedFindingID == far.id
        )

        // ── Hovering a note tints its passage ────────────────────────────
        print("\nHovering a note tints its passage")

        critique.selectedFindingID = nil
        critique.endHover(middle.id)
        critique.endHover(far.id)
        settle(for: 0.3)

        critique.hover(middle.id)
        settle(for: 0.3)
        check(
            "hovering draws the hovered passage in the hover wash",
            colour(of: middle, in: textView)
                == CritiqueSeverity.medium.hoveredHighlight(on: .light)
        )
        check(
            "and leaves every other passage in its resting wash",
            colour(of: far, in: textView) == restingColour(for: far)
        )

        let offsetBeforeHover = scrollView.contentView.bounds.minY
        critique.hover(far.id)
        settle(for: 0.3)
        check(
            "hovering never scrolls the document",
            abs(scrollView.contentView.bounds.minY - offsetBeforeHover) < 1,
            "moved to \(Int(scrollView.contentView.bounds.minY)) from "
                + "\(Int(offsetBeforeHover))"
        )

        critique.selectedFindingID = middle.id
        critique.hover(middle.id)
        settle(for: 0.3)
        check(
            "selection wins over hover on the same finding",
            colour(of: middle, in: textView)
                == CritiqueSeverity.medium.selectedHighlight(on: .light)
        )
        // And the open note's passage is ruled as well as washed, which is
        // what makes a press land visibly when the passage was already on
        // screen and nothing scrolled.
        check(
            "the open note's passage is ruled",
            rule(of: middle, in: textView)
                == CritiqueSeverity.medium.selectionRule(on: .light)
        )
        check(
            "and no other passage is",
            rule(of: far, in: textView) == nil
        )

        critique.endHover(middle.id)
        critique.selectedFindingID = nil
        settle(for: 0.3)
        check(
            "and clearing the hover puts the wash back",
            colour(of: middle, in: textView) == restingColour(for: middle)
        )
        check(
            "and closing the note takes the rule away with it",
            rule(of: middle, in: textView) == nil
        )

        // Hovering does not rule a passage. The reader asked a question by
        // pointing and answered it by pressing, and the two answers have to
        // look different or the press feels like it did nothing.
        critique.hover(middle.id)
        settle(for: 0.3)
        check(
            "hovering tints the passage without ruling it",
            colour(of: middle, in: textView)
                == CritiqueSeverity.medium.hoveredHighlight(on: .light)
                && rule(of: middle, in: textView) == nil
        )
        critique.endHover(middle.id)
        settle(for: 0.2)

        // Moving the pointer straight from one note to the next delivers the
        // arrival before the departure often enough to matter. A naive
        // clear turns the new highlight off again, which on screen is a
        // flicker rather than a move.
        critique.hover(middle.id)
        critique.hover(far.id)
        critique.endHover(middle.id)
        settle(for: 0.3)
        check(
            "a late hover-out from the note just left does not clear the new one",
            colour(of: far, in: textView)
                == CritiqueSeverity.high.hoveredHighlight(on: .light)
                && colour(of: middle, in: textView) == restingColour(for: middle)
        )
        critique.endHover(far.id)

        checkANotePassesItsClicksOn()

        print("\n\(checks - failures)/\(checks) checks passed")
        exit(failures == 0 ? 0 : 1)
    }

    /// Does a press on a note's *words* reach the note?
    ///
    /// This is the half of the reported bug that no scroll arithmetic could
    /// have explained. `.textSelection(.enabled)` puts an
    /// `AppKitTextInteractionView` over the text, and an AppKit view that
    /// takes the hit swallows the press before SwiftUI's gesture system is
    /// reached — so the note answered a click on its margin and ignored a
    /// click on itself, which is most of it.
    ///
    /// Asked with `hitTest` rather than with a synthesised press: a press
    /// synthesised into a window that is deliberately never ordered front is
    /// not delivered at all, so it cannot tell a swallowed click from an
    /// off-screen one. Which view answers for the point is the same question
    /// the mouse asks and has an answer either way.
    private static func checkANotePassesItsClicksOn() {
        print("\nA press on a note's words reaches the note")

        let finding = CritiqueFinding(
            severity: .high,
            category: "Clarity",
            location: "Opening, paragraph 2",
            quote: "the sentence in question",
            why: "This note carries enough words that the middle of it is "
                + "words rather than padding, which is the whole point.",
            fix: "Put the point first, and the qualification after it."
        )
        let item = CritiqueModel.Item(
            finding: finding,
            range: NSRange(location: 0, length: 4)
        )
        let card = CritiqueCard(
            item: item,
            colorTheme: EditorColorTheme(color: .blue, mode: .light),
            isSelected: false,
            onTap: {},
            onHoverChange: { _ in },
            onResolve: { _ in }
        )
        .frame(width: 320)

        let frame = NSRect(x: 0, y: 0, width: 340, height: 420)
        let hosting = NSHostingView(rootView: AnyView(card))
        hosting.frame = frame
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        window.orderBack(nil)
        settle(for: 0.8)
        hosting.layoutSubtreeIfNeeded()
        settle(for: 0.4)

        // Across the note, not at one point: a single sample can land in a gap
        // between two paragraphs and pass while every word swallows the press.
        var swallowed: [String] = []
        for y in stride(from: 140.0, through: 280.0, by: 20.0) {
            guard let hit = hosting.hitTest(NSPoint(x: 170, y: y)) else {
                continue
            }
            let name = String(describing: type(of: hit))
            if name.contains("TextInteraction") || name.contains("TextView") {
                swallowed.append("y \(Int(y)) → \(name)")
            }
        }
        check(
            "no view over the note's words takes the press",
            swallowed.isEmpty,
            swallowed.joined(separator: ", ")
        )
    }

    private static func editor() -> RichTextEditor {
        RichTextEditor(
            text: Binding(get: { Harness.draft }, set: { Harness.draft = $0 }),
            documentURL: nil,
            session: session!,
            colorTheme: EditorColorTheme(color: .blue, mode: .light),
            layoutWidth: 760,
            page: MarkdownPageMetrics(measure: 700, bleed: 60),
            critique: critique
        )
    }

    /// Puts the pane in the state a reader who has just typed leaves it in:
    /// parked near the top with its layout thrown away and rebuilt only as far
    /// as the screenful it is showing.
    private static func reStyleAfterAnEdit(scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        draft += " "
        critique.noteCurrentText(draft)
        hosting?.rootView = editor()
        // Just long enough for SwiftUI to run the update that re-styles, and
        // no longer: AppKit lays the rest of the document out in the
        // background, and waiting for it is waiting for the bug to go away.
        settle(for: 0.12)
    }

    /// Where the finding's passage sits in the *rendered* text.
    ///
    /// The critique's range is a source offset and this pane shows the
    /// Markdown with its syntax removed, so the two disagree by however much
    /// markup came before the passage. Finding the quote in the text the view
    /// is displaying is the same answer by a route that does not need the
    /// coordinator's private render model.
    private static func renderedRange(
        of finding: CritiqueFinding,
        in textView: NSTextView
    ) -> NSRange {
        (textView.string as NSString).range(of: finding.quote)
    }

    /// The passage's rectangle in the text view's own coordinates, measured
    /// exactly as the editor measures it.
    private static func passageRect(
        of finding: CritiqueFinding,
        in textView: NSTextView
    ) -> CGRect? {
        guard let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            return nil
        }
        let rendered = renderedRange(of: finding, in: textView)
        guard rendered.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: rendered,
            actualCharacterRange: nil
        )
        let box = layoutManager.boundingRect(
            forGlyphRange: glyphs,
            in: container
        )
        guard box.height > 0 else { return nil }
        return box.offsetBy(dx: 0, dy: textView.textContainerInset.height)
    }

    /// The wash the view is actually drawing behind a finding's passage.
    private static func colour(
        of finding: CritiqueFinding,
        in textView: RichMarkdownTextView
    ) -> NSColor? {
        textView.critiqueHighlights.first { $0.id == finding.id }?.colour
    }

    private static func restingColour(for finding: CritiqueFinding) -> NSColor {
        finding.severity.highlight(on: .light)
    }

    /// The rule the view is actually drawing under a finding's passage.
    private static func rule(
        of finding: CritiqueFinding,
        in textView: RichMarkdownTextView
    ) -> NSColor? {
        textView.critiqueHighlights.first { $0.id == finding.id }?.rule
    }

    private static func settle(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(
                mode: .default,
                before: Date().addingTimeInterval(0.02)
            )
        }
    }
}
