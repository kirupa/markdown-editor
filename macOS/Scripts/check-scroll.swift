#!/usr/bin/env swift

// Runtime checks for the "never jump" contract.
//
// The pure arithmetic lives in `EditorScrollGeometry` and is unit-tested in
// the shared package. Everything that actually went wrong, though, went wrong
// in AppKit: a clip view with no height, a document frame reporting only the
// part that had been laid out, a caret reveal undone by a later scroll
// restore. None of that is reachable from a unit test, and every one of those
// bugs passed the suite.
//
// So these checks drive real NSTextViews configured the way the editor
// configures them, and assert the behaviour the editor depends on. Run with
// `make check-scroll`. Exits non-zero on the first failure.

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: - Harness

var failures = 0
var checks = 0

func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    checks += 1
    if passed {
        print("  ok    \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
}

/// A scroll view and text view configured as `RichTextEditor` and
/// `SourceTextEditor` configure theirs. The details matter: a text container
/// that tracks the view's width, a resizable text view, and overlay scrollers.
func makePane(
    width: CGFloat = 900,
    height: CGFloat = 600
) -> (NSScrollView, NSTextView) {
    let scrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: width, height: height)
    )
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let textView = NSTextView(frame: scrollView.bounds)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainerInset = NSSize(width: 24, height: 20)
    textView.textContainer?.containerSize = NSSize(
        width: width - 48,
        height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    scrollView.documentView = textView

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    window.orderBack(nil)
    return (scrollView, textView)
}

func document(lines: Int) -> NSAttributedString {
    let text = NSMutableAttributedString()
    for index in 0..<lines {
        text.append(
            NSAttributedString(
                string:
                    "Line \(index) with enough body text on it to wrap once.\n",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
        )
    }
    return text
}

// MARK: - The behaviours the editor relies on

/// `EditorScrollSynchronizer.prepareLayout(toRestore:)` measures only as far
/// as the restored viewport, on the premise that a partial layout grows the
/// document frame far enough for the scroll clamp to leave the offset alone.
///
/// The starting state is the whole point of this check. A text view that has
/// already been laid out keeps its frame height — AppKit never shrinks it —
/// so re-styling such a pane cannot lose the offset and proves nothing. The
/// pane that loses it is one that has *not* been laid out yet, which is what
/// `render` finds when a document is first opened into it. There a document
/// 34057pt tall reports the 600pt of its viewport, and a reader restored to
/// 5000pt is clamped to the very top.
func checkTargetedLayoutRestoresOffset() {
    print("\nTargeted layout restores an exact offset on an unmeasured pane")
    for lines in [500, 2000, 8000] {
        for wanted in [CGFloat(0), 300, 5000] {
            let (scrollView, textView) = makePane()
            guard let container = textView.textContainer,
                let layoutManager = textView.layoutManager
            else { continue }

            // A pane in the state `render` finds it: text set, nothing laid
            // out beyond what is on screen.
            textView.textStorage?.setAttributedString(document(lines: lines))

            let viewport = scrollView.contentView.bounds.height
            layoutManager.ensureLayout(
                forBoundingRect: NSRect(
                    x: 0,
                    y: 0,
                    width: max(1, container.size.width),
                    height: wanted + viewport + 400
                ),
                in: container
            )
            scrollView.layoutSubtreeIfNeeded()
            scrollView.documentView?.layoutSubtreeIfNeeded()

            let height = textView.frame.height
            let clamped = min(max(wanted, 0), max(0, height - viewport))
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            // The document has to be long enough for the offset to be real,
            // otherwise the check passes for the wrong reason.
            let reachable = wanted <= max(0, height - viewport) + 0.5
            let landed = scrollView.contentView.bounds.minY
            check(
                "\(lines) lines restored to \(Int(wanted))",
                reachable && abs(landed - wanted) <= 0.5,
                "landed \(Int(landed)) in a \(Int(height))pt frame"
            )
        }
    }
}

/// A pane that has just been created — entering Split, say — has laid out only
/// the screenful it shows, so it reports a document exactly as tall as its
/// viewport. Converting a fraction against that height puts a reader 80%
/// through a long document back at the very top. `setNormalizedPosition`
/// therefore forces a full layout before it measures.
func checkReceiverMeasuresBeforeConverting() {
    print("\nA newly created pane is measured before a position is applied")
    for lines in [2000, 8000] {
        let (scrollView, textView) = makePane()
        guard let container = textView.textContainer,
            let layoutManager = textView.layoutManager
        else { continue }

        textView.textStorage?.setAttributedString(document(lines: lines))

        // What the pane claims before anyone insists it measure itself.
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        let unmeasured = textView.frame.height

        layoutManager.ensureLayout(for: container)
        scrollView.layoutSubtreeIfNeeded()
        let measured = textView.frame.height

        check(
            "\(lines) lines: an unmeasured pane understates its height",
            unmeasured < measured / 2,
            "\(Int(unmeasured))pt claimed vs \(Int(measured))pt real"
        )

        let viewport = scrollView.contentView.bounds.height
        let target = 0.8 * max(0, measured - viewport)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let landed = scrollView.contentView.bounds.minY

        check(
            "\(lines) lines: 80% lands 80% of the way down",
            abs(landed - target) <= 0.5,
            "landed \(Int(landed)) of \(Int(target))"
        )
    }
}

/// `render` and `preservingScrollPosition` both restore the scroll offset and
/// only then reveal the caret. Reversing those two steps leaves the caret off
/// screen, which is how a writer loses their place after a formatting command.
func checkCaretRevealHappensAfterRestore() {
    print("\nThe caret is revealed after the offset is restored")
    let (scrollView, textView) = makePane()
    guard let container = textView.textContainer,
        let layoutManager = textView.layoutManager
    else { return }

    textView.textStorage?.setAttributedString(document(lines: 2000))
    layoutManager.ensureLayout(for: container)
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let caret = NSRange(location: 9200, length: 0)
    check(
        "the caret starts off screen",
        !isSelectionVisible(caret, in: textView)
    )

    let remembered = scrollView.contentView.bounds.minY
    textView.textStorage?.setAttributedString(document(lines: 2000))
    layoutManager.ensureLayout(
        forBoundingRect: NSRect(
            x: 0,
            y: 0,
            width: max(1, container.size.width),
            height: remembered + scrollView.contentView.bounds.height + 400
        ),
        in: container
    )
    let height = textView.frame.height
    let viewport = scrollView.contentView.bounds.height
    scrollView.contentView.scroll(
        to: NSPoint(x: 0, y: min(max(remembered, 0), max(0, height - viewport)))
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)
    textView.setSelectedRange(caret)
    if !isSelectionVisible(caret, in: textView) {
        textView.scrollRangeToVisible(caret)
    }

    check(
        "the caret is on screen once the sequence finishes",
        isSelectionVisible(caret, in: textView)
    )
}

/// The reveal is skipped when the caret is already visible, so ordinary typing
/// never moves the page. A selection taller than the viewport can never be
/// contained, so that case falls back to intersection.
func checkVisibleCaretDoesNotMoveThePage() {
    print("\nAn already visible caret does not move the page")
    let (scrollView, textView) = makePane()
    guard let container = textView.textContainer,
        let layoutManager = textView.layoutManager
    else { return }

    textView.textStorage?.setAttributedString(document(lines: 2000))
    layoutManager.ensureLayout(for: container)
    scrollView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    var onScreen: NSRange?
    for location in stride(from: 0, to: 130_000, by: 200) {
        let candidate = NSRange(location: location, length: 0)
        if isSelectionVisible(candidate, in: textView) {
            onScreen = candidate
            break
        }
    }
    guard let caret = onScreen else {
        check("found a caret inside the viewport", false)
        return
    }

    let before = scrollView.contentView.bounds.minY
    textView.setSelectedRange(caret)
    if !isSelectionVisible(caret, in: textView) {
        textView.scrollRangeToVisible(caret)
    }
    let after = scrollView.contentView.bounds.minY

    check(
        "the page held still",
        abs(after - before) <= 0.5,
        "\(Int(before)) -> \(Int(after))"
    )
}

/// A line straddling the edge of the viewport is not visible, and treating it
/// as visible means it is never revealed and never corrects itself.
func checkPartiallyVisibleCaretCountsAsHidden() {
    print("\nA caret straddling the viewport edge counts as hidden")
    let (scrollView, textView) = makePane()
    guard let container = textView.textContainer,
        let layoutManager = textView.layoutManager
    else { return }

    textView.textStorage?.setAttributedString(document(lines: 2000))
    layoutManager.ensureLayout(for: container)
    scrollView.layoutSubtreeIfNeeded()

    // Find a line, then park the viewport so its bottom edge cuts through it.
    let probe = NSRange(location: 4000, length: 0)
    let glyphs = layoutManager.glyphRange(
        forCharacterRange: probe,
        actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    rect.origin.y += textView.textContainerOrigin.y

    let viewport = scrollView.contentView.bounds.height
    let straddling = rect.midY - viewport
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: straddling))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    let visible = scrollView.contentView.bounds
    check(
        "the line really does straddle the edge",
        rect.minY < visible.maxY && rect.maxY > visible.maxY,
        "line \(Int(rect.minY))-\(Int(rect.maxY)), edge \(Int(visible.maxY))"
    )
    check(
        "it is reported as not visible",
        !isSelectionVisible(probe, in: textView)
    )
}

/// The same rule `MarkdownEditingSurface` applies, restated here so this check
/// exercises the behaviour rather than importing the app target (which is an
/// executable and cannot be linked against).
func isSelectionVisible(_ range: NSRange, in textView: NSTextView) -> Bool {
    guard let layoutManager = textView.layoutManager,
        let container = textView.textContainer
    else {
        return false
    }
    let glyphs = layoutManager.glyphRange(
        forCharacterRange: range,
        actualCharacterRange: nil
    )
    var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    let origin = textView.textContainerOrigin
    rect.origin.x += origin.x
    rect.origin.y += origin.y
    if rect.height <= 0 {
        rect.size.height = textView.font?.boundingRectForFont.height ?? 16
    }
    if rect.width <= 0 {
        rect.size.width = 1
    }

    let visible = textView.visibleRect
    if rect.height >= visible.height {
        return visible.intersects(rect)
    }
    return visible.contains(rect)
}

/// Replacing a text view's storage makes AppKit move the selection before the
/// intended one is restored, and it announces that intermediate value through
/// the delegate exactly as it announces a real caret move.
///
/// This is the whole reason `RichTextEditor` and `SourceTextEditor` suppress
/// selection notifications while they re-style. Both panes re-style on every
/// keystroke and publish selection changes to the other pane, which reveals
/// them; an intermediate value measured at 19,681 characters from the caret
/// therefore threw the other pane most of the way down the document and back
/// again on every character typed.
///
/// The check is written as the two halves of the decision: an unguarded
/// delegate sees a value that is not the caret, and a guarded one does not.
func checkRestylingAnnouncesAnIntermediateSelection() {
    print("\nReplacing the text storage announces a selection that is not the caret")

    final class Recorder: NSObject, NSTextViewDelegate {
        var isRestyling = false
        var unguarded: [NSRange] = []
        var guarded: [NSRange] = []

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            unguarded.append(textView.selectedRange())
            guard !isRestyling else {
                return
            }
            guarded.append(textView.selectedRange())
        }
    }

    let (scrollView, textView) = makePane()
    guard let container = textView.textContainer,
        let layoutManager = textView.layoutManager
    else { return }

    textView.textStorage?.setAttributedString(document(lines: 2000))
    layoutManager.ensureLayout(for: container)
    scrollView.layoutSubtreeIfNeeded()

    // A caret near the top, which is where the jump was reported from.
    let caret = NSRange(location: 35, length: 0)
    textView.setSelectedRange(caret)

    let recorder = Recorder()
    textView.delegate = recorder

    // Exactly what a re-style does: replace the storage, then put the caret
    // back where it belongs.
    recorder.isRestyling = true
    textView.textStorage?.setAttributedString(document(lines: 2000))
    textView.setSelectedRange(caret)
    recorder.isRestyling = false

    let strays = recorder.unguarded.filter { $0 != caret }
    check(
        "an unguarded delegate is told the caret moved somewhere it did not",
        !strays.isEmpty,
        strays.isEmpty
            ? "no intermediate seen"
            : "saw \(strays.map(\.location))"
    )
    check(
        "the stray value is far from the caret, not a rounding difference",
        strays.contains { abs($0.location - caret.location) > 1000 },
        "caret \(caret.location), strays \(strays.map(\.location))"
    )
    check(
        "a delegate guarded while re-styling publishes nothing",
        recorder.guarded.isEmpty,
        "published \(recorder.guarded.map(\.location))"
    )
    check(
        "and the caret really is back where it started afterwards",
        textView.selectedRange() == caret,
        "\(textView.selectedRange())"
    )
}

// MARK: - Run

print("Editor scroll checks")
checkTargetedLayoutRestoresOffset()
checkReceiverMeasuresBeforeConverting()
checkCaretRevealHappensAfterRestore()
checkVisibleCaretDoesNotMoveThePage()
checkPartiallyVisibleCaretCountsAsHidden()
checkRestylingAnnouncesAnIntermediateSelection()

print("\n\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
