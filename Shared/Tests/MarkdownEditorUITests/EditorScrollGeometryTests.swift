import CoreGraphics
import Foundation
import Testing

@testable import MarkdownEditorUI

/// A pane that is re-styling has not finished measuring itself, and the
/// figures it reports in that moment used to be taken at face value. Applying
/// them threw the reader far down the document and the caret-reveal snapped
/// everything back, which is the jump a writer saw while typing near the top.
///
/// The numbers below are the ones an instrumented build actually recorded on
/// a 519-line document, so these tests fail against the behavior that shipped.
@Suite("Editor scroll geometry")
struct EditorScrollGeometryTests {
    // MARK: - The recorded failure

    @Test("A pane measured mid-relayout reports no position")
    func midRelayoutHasNoPosition() {
        // Recorded during a re-style: 20pt down a document whose real height
        // was 29629pt, but only 114pt of it had been laid out and the
        // viewport had not been sized at all.
        let geometry = EditorScrollGeometry(
            documentHeight: 114,
            viewportHeight: 0,
            offset: 20
        )

        #expect(geometry.isResolved == false)
        #expect(geometry.normalizedPosition == nil)
    }

    @Test("The recorded jump is not reachable from a settled pane")
    func recordedJumpIsUnreachable() {
        // The old code turned the mid-relayout figures into 20/114 = 0.175
        // and applied that to the finished document, landing 5198pt down.
        let unresolved = EditorScrollGeometry(
            documentHeight: 114,
            viewportHeight: 0,
            offset: 20
        )
        #expect(unresolved.normalizedPosition == nil)

        // Had the fraction escaped, this is where it would have gone.
        let settled = EditorScrollGeometry(
            documentHeight: 29629,
            viewportHeight: 572,
            offset: 20
        )
        let wrongTarget = settled.offset(forNormalizedPosition: 0.1754386)
        #expect(wrongTarget != nil)
        #expect(abs((wrongTarget ?? 0) - 5100) < 200)

        // What the settled pane actually reports is a hair off the top.
        let position = try? #require(settled.normalizedPosition)
        #expect((position ?? 1) < 0.001)
    }

    @Test("An offset beyond the document means the figures disagree")
    func inconsistentFiguresAreRejected() {
        // Mid-restyle the offset survives from the old document while the
        // height reflects only what has been laid out of the new one.
        let geometry = EditorScrollGeometry(
            documentHeight: 400,
            viewportHeight: 572,
            offset: 3000
        )

        #expect(geometry.maximumOffset == 0)
        #expect(geometry.isResolved == false)
        #expect(geometry.normalizedPosition == nil)
    }

    // MARK: - Settled panes still work

    @Test("A settled pane reports where it sits")
    func settledPaneReportsPosition() {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 500,
            offset: 750
        )

        #expect(geometry.isResolved)
        #expect(geometry.maximumOffset == 1500)
        #expect(geometry.normalizedPosition == 0.5)
    }

    @Test("A document shorter than its viewport sits at the top")
    func shortDocumentIsResolved() {
        let geometry = EditorScrollGeometry(
            documentHeight: 200,
            viewportHeight: 500,
            offset: 0
        )

        // Nothing to scroll is a real answer, not an unmeasured one.
        #expect(geometry.isResolved)
        #expect(geometry.maximumOffset == 0)
        #expect(geometry.normalizedPosition == 0)
    }

    @Test("An empty document has nothing to report")
    func emptyDocumentHasNoPosition() {
        let geometry = EditorScrollGeometry(
            documentHeight: 0,
            viewportHeight: 500,
            offset: 0
        )

        #expect(geometry.isResolved == false)
        #expect(geometry.normalizedPosition == nil)
    }

    @Test("The bottom of the document is one whole travel")
    func bottomIsOne() {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 500,
            offset: 1500
        )

        #expect(geometry.normalizedPosition == 1)
    }

    @Test(
        "Positions stay inside their travel",
        arguments: [
            (CGFloat(-3), CGFloat(0)),
            (CGFloat(0), CGFloat(0)),
            (CGFloat(0.25), CGFloat(375)),
            (CGFloat(1), CGFloat(1500)),
            (CGFloat(4), CGFloat(1500))
        ]
    )
    func positionsAreClamped(position: CGFloat, expected: CGFloat) {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 500,
            offset: 0
        )

        #expect(geometry.offset(forNormalizedPosition: position) == expected)
    }

    @Test("An unmeasured pane cannot place a position")
    func unmeasuredPaneCannotPlacePosition() {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 0,
            offset: 0
        )

        #expect(geometry.offset(forNormalizedPosition: 0.5) == nil)
    }

    // MARK: - Round trips

    @Test(
        "Reading a position and putting it back does not move the pane",
        arguments: [CGFloat(0), 1, 137.5, 900, 1499.5, 1500]
    )
    func roundTripIsStable(offset: CGFloat) {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 500,
            offset: offset
        )

        let position = geometry.normalizedPosition
        #expect(position != nil)
        let restored = geometry.offset(forNormalizedPosition: position ?? 0)
        #expect(abs((restored ?? -1) - offset) < 0.001)
    }

    // MARK: - Holding the pane still

    @Test("Restoring an exact offset survives the document growing")
    func exactOffsetSurvivesGrowth() {
        // Typing near the top makes the document taller. A fraction of the
        // travel would move the text under the reader; the offset does not.
        let before = EditorScrollGeometry(
            documentHeight: 29629,
            viewportHeight: 572,
            offset: 240
        )
        let after = EditorScrollGeometry(
            documentHeight: 29700,
            viewportHeight: 572,
            offset: 240
        )

        #expect(after.clampedOffset(before.offset) == 240)

        // The same move expressed as a fraction drifts.
        let fraction = try? #require(before.normalizedPosition)
        let drifted = after.offset(forNormalizedPosition: fraction ?? 0)
        #expect((drifted ?? 0) > 240)
    }

    @Test("Restoring is clamped when the document shrinks")
    func restoreClampsWhenDocumentShrinks() {
        let shrunk = EditorScrollGeometry(
            documentHeight: 900,
            viewportHeight: 500,
            offset: 0
        )

        #expect(shrunk.clampedOffset(5000) == 400)
        #expect(shrunk.clampedOffset(-20) == 0)
        #expect(shrunk.clampedOffset(250) == 250)
    }

    @Test("Sub-point corrections are not worth making")
    func subPointMovesAreIgnored() {
        let geometry = EditorScrollGeometry(
            documentHeight: 2000,
            viewportHeight: 500,
            offset: 300
        )

        #expect(geometry.shouldMove(to: 300) == false)
        #expect(geometry.shouldMove(to: 300.4) == false)
        #expect(geometry.shouldMove(to: 300.6))
        #expect(geometry.shouldMove(to: 299.4))
    }

    @Test("A pane already where it is asked to go does not move")
    func noMoveWhenAlreadyThere() {
        let geometry = EditorScrollGeometry(
            documentHeight: 29629,
            viewportHeight: 572,
            offset: 5198
        )

        #expect(geometry.shouldMove(to: 5198) == false)
    }

    // MARK: - Degenerate figures

    @Test(
        "Nonsense figures never produce a position",
        arguments: [
            EditorScrollGeometry(
                documentHeight: -100,
                viewportHeight: 500,
                offset: 0
            ),
            EditorScrollGeometry(
                documentHeight: 500,
                viewportHeight: -100,
                offset: 0
            ),
            EditorScrollGeometry(
                documentHeight: 0,
                viewportHeight: 0,
                offset: 0
            )
        ]
    )
    func nonsenseFiguresHaveNoPosition(geometry: EditorScrollGeometry) {
        #expect(geometry.normalizedPosition == nil)
    }

    @Test("Maximum offset is never negative")
    func maximumOffsetIsNeverNegative() {
        let geometry = EditorScrollGeometry(
            documentHeight: 100,
            viewportHeight: 900,
            offset: 0
        )

        #expect(geometry.maximumOffset == 0)
    }

    // MARK: - Why the receiving pane has to force layout

    /// The sending pane withholds a fraction until it is fully measured. The
    /// receiving pane needs the same care, and these two tests record why that
    /// cannot be arranged here.
    ///
    /// A pane that has only ever laid out the screenful it shows reports a
    /// document exactly as tall as its viewport. Every rule in this type finds
    /// that perfectly reasonable — there is no contradiction to detect, the
    /// figures agree with each other, they are simply not the whole document.
    /// So the guard has to be in the caller, which is the one place that can
    /// ask AppKit to finish measuring.
    @Test("A pane that has only laid out its first screen looks settled")
    func freshPaneLooksSettled() {
        // Measured from a real NSTextView holding an 8000-line document that
        // had been given its text but never fully laid out: the frame was
        // still the 600pt of the viewport, against a true height of 136017pt.
        let fresh = EditorScrollGeometry(
            documentHeight: 600,
            viewportHeight: 600,
            offset: 0
        )

        #expect(fresh.isResolved)
        #expect(fresh.normalizedPosition == 0)
    }

    @Test("Applying a fraction to an unmeasured pane lands at the top")
    func unmeasuredPaneCollapsesEveryPosition() {
        let fresh = EditorScrollGeometry(
            documentHeight: 600,
            viewportHeight: 600,
            offset: 0
        )
        let measured = EditorScrollGeometry(
            documentHeight: 136_017,
            viewportHeight: 600,
            offset: 0
        )

        // A reader 80% through a long document, synced into a pane that has
        // not been measured, is put back at the very top: the document has no
        // travel yet, so every fraction collapses onto zero.
        #expect(fresh.offset(forNormalizedPosition: 0.8) == 0)

        // Once the pane is measured the same fraction lands where it should.
        let target = try! #require(measured.offset(forNormalizedPosition: 0.8))
        #expect(abs(target - 108_333.6) < 1)
    }
    // MARK: - Being taken to a passage

    /// The numbers are the ones the reveal check recorded against real views
    /// on a 1,200-paragraph draft: a pane 600pt tall onto a document
    /// 112,951pt tall, with the criticised passage 112,590pt down.
    @Test("A passage is framed a third down, not pinned to an edge")
    func revealFramesThePassage() {
        let pane = EditorScrollGeometry(
            documentHeight: 30_000,
            viewportHeight: 600,
            offset: 0
        )

        // A third of 600 is 200, so a passage 10,000pt down is shown with
        // 200pt of what came before it still on screen.
        #expect(
            pane.offset(toReveal: (minY: 10_000, height: 18)) == 9_800
        )
    }

    @Test("A passage near the top is not dragged down to meet the rule")
    func revealClampsAtTheTop() {
        let pane = EditorScrollGeometry(
            documentHeight: 30_000,
            viewportHeight: 600,
            offset: 5_000
        )

        // 40 - 200 is negative, and the document has no room above its first
        // line. The clamp is the whole answer; there is no separate rule.
        #expect(pane.offset(toReveal: (minY: 40, height: 18)) == 0)
    }

    @Test("A passage near the end stops at the document's last screenful")
    func revealClampsAtTheEnd() {
        let pane = EditorScrollGeometry(
            documentHeight: 112_951,
            viewportHeight: 600,
            offset: 0
        )

        // The recorded case: the rule asks for 112,390 and the document only
        // has 112,351 of travel, so the passage ends up lower in the window
        // than a third — which is correct, and is why the check compares
        // against this function rather than against a fraction of the window.
        #expect(
            pane.offset(toReveal: (minY: 112_590, height: 18)) == 112_351
        )
    }

    @Test("A passage taller than the window starts at its first line")
    func revealTopsOutALongPassage() {
        let pane = EditorScrollGeometry(
            documentHeight: 30_000,
            viewportHeight: 600,
            offset: 0
        )

        // Framing something that cannot be framed would begin the reader a
        // third of the way into a quotation they were sent to read.
        #expect(pane.offset(toReveal: (minY: 10_000, height: 900)) == 10_000)
        // And exactly the height of the window counts as too tall: framing it
        // would push its last line off the bottom.
        #expect(pane.offset(toReveal: (minY: 10_000, height: 600)) == 10_000)
    }

    @Test("A document shorter than its window never moves")
    func revealDoesNothingWithNoTravel() {
        let pane = EditorScrollGeometry(
            documentHeight: 400,
            viewportHeight: 600,
            offset: 0
        )

        #expect(pane.offset(toReveal: (minY: 300, height: 18)) == 0)
    }

    @Test("A passage the reader is already looking at is left alone")
    func comfortablyVisiblePassagesAreNotMoved() {
        let pane = EditorScrollGeometry(
            documentHeight: 30_000,
            viewportHeight: 600,
            offset: 10_000
        )

        // Well inside the window: clicking this passage in the *text* must not
        // move the page under the pointer that just landed on it.
        #expect(pane.isComfortablyVisible((minY: 10_300, height: 18)))

        // Visible, but jammed against the bottom edge with nothing after it.
        // That is exactly what the reveal exists to fix, so it does not count.
        #expect(!pane.isComfortablyVisible((minY: 10_590, height: 18)))
        // And the same against the top edge.
        #expect(!pane.isComfortablyVisible((minY: 10_010, height: 18)))
        // Off screen entirely.
        #expect(!pane.isComfortablyVisible((minY: 20_000, height: 18)))
    }

    @Test("A passage taller than the window is judged by its first line")
    func longPassagesAreJudgedByTheirStart() {
        let pane = EditorScrollGeometry(
            documentHeight: 30_000,
            viewportHeight: 600,
            offset: 10_000
        )

        // It cannot be shown whole, so requiring that would re-reveal it on
        // every press and drag the page each time.
        #expect(pane.isComfortablyVisible((minY: 10_100, height: 5_000)))
    }

    @Test("An unmeasured pane cannot say a passage is visible")
    func unmeasuredPaneIsNeverComfortable() {
        let fresh = EditorScrollGeometry(
            documentHeight: 600,
            viewportHeight: 0,
            offset: 0
        )

        #expect(!fresh.isComfortablyVisible((minY: 0, height: 18)))
    }
}
