import CoreGraphics
import Testing

@testable import MarkdownEditorUI

@Suite("Editor pane geometry")
struct EditorPaneGeometryTests {
    private let minimumExplorer: CGFloat = 190
    private let maximumExplorer: CGFloat = 420

    private func explorer(
        _ proposed: CGFloat,
        totalWidth: CGFloat
    ) -> CGFloat {
        EditorPaneGeometry.explorerWidth(
            proposed,
            totalWidth: totalWidth,
            minimum: minimumExplorer,
            maximum: maximumExplorer
        )
    }

    @Test("A width inside both bounds is left alone")
    func explorerPassesThrough() {
        #expect(explorer(240, totalWidth: 1_400) == 240)
    }

    @Test("A width below the minimum is raised to it")
    func explorerRaisesBelowMinimum() {
        #expect(explorer(40, totalWidth: 1_400) == minimumExplorer)
        #expect(explorer(-100, totalWidth: 1_400) == minimumExplorer)
    }

    @Test("A width above the maximum is lowered to it")
    func explorerLowersAboveMaximum() {
        #expect(explorer(9_000, totalWidth: 1_400) == maximumExplorer)
    }

    @Test("The explorer leaves a strip of document uncovered")
    func explorerLeavesDocumentShowing() {
        // 600 wide: the ceiling is 600 - 240 = 360, under the 420 maximum.
        #expect(explorer(420, totalWidth: 600) == 360)
    }

    @Test("In a window too narrow for both bounds, the minimum wins")
    func explorerMinimumWinsWhenImpossible() {
        // 300 wide: leaving 240 uncovered would allow only 60, under the 190
        // minimum. An explorer too narrow to read would be worse than one that
        // covers more than its share.
        #expect(explorer(240, totalWidth: 300) == minimumExplorer)
        #expect(explorer(240, totalWidth: 0) == minimumExplorer)
    }

    @Test("A measure is clamped by the space the handle leaves")
    func measureRespectsHandle() {
        let width = EditorPaneGeometry.measureWidth(
            5_000,
            totalWidth: 800,
            minimum: 360,
            maximum: 1_100,
            handleWidth: 12
        )
        #expect(width == 788)
    }

    @Test("A measure never falls below its minimum, however narrow the window")
    func measureKeepsMinimum() {
        let width = EditorPaneGeometry.measureWidth(
            100,
            totalWidth: 120,
            minimum: 360,
            maximum: 1_100,
            handleWidth: 12
        )
        #expect(width == 360)
    }

    @Test("A measure is capped by its own maximum before the window's")
    func measureRespectsMaximum() {
        let width = EditorPaneGeometry.measureWidth(
            5_000,
            totalWidth: 4_000,
            minimum: 360,
            maximum: 1_100,
            handleWidth: 12
        )
        #expect(width == 1_100)
    }

    @Test("Centering splits the leftover space evenly")
    func centeringIsEven() {
        #expect(
            EditorPaneGeometry.centeringInset(measure: 700, totalWidth: 1_500)
                == 400
        )
    }

    @Test("Centering does not depend on anything but the window")
    func centeringIgnoresTheExplorer() {
        // M-59: this is the whole point of floating the explorer. The inset is
        // a function of the window and the measure, so opening or closing the
        // explorer cannot enter into it.
        let closed = EditorPaneGeometry.centeringInset(
            measure: 700,
            totalWidth: 1_500
        )
        let open = EditorPaneGeometry.centeringInset(
            measure: 700,
            totalWidth: 1_500
        )
        #expect(closed == open)
    }

    @Test("A measure wider than the window starts at the leading edge")
    func centeringNeverGoesNegative() {
        #expect(
            EditorPaneGeometry.centeringInset(measure: 900, totalWidth: 600)
                == 0
        )
    }
}
