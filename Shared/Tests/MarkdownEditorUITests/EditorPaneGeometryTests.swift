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

    // MARK: - The page, and the column inside it

    @Test("A roomy window gives a picture the full bleed each side")
    func bleedIsTheFullHundredWhenThereIsRoom() {
        #expect(
            EditorPaneGeometry.imageBleed(around: 700, within: 1_400) == 100
        )
    }

    @Test("A tight window gives away only the room it has")
    func bleedIsWhateverIsLeftOver() {
        // 60 points spare, 30 a side.
        #expect(
            EditorPaneGeometry.imageBleed(around: 700, within: 760) == 30
        )
    }

    @Test("A window no wider than the column gives no bleed at all")
    func bleedCollapsesRatherThanGoingNegative() {
        #expect(EditorPaneGeometry.imageBleed(around: 700, within: 700) == 0)
        // A phone: the document is the screen, so there is no margin. The rest
        // of the model has to keep working, with the page equal to the column.
        #expect(EditorPaneGeometry.imageBleed(around: 390, within: 390) == 0)
        #expect(EditorPaneGeometry.imageBleed(around: 700, within: 500) == 0)
    }

    @Test("The page is the column plus a bleed on each side")
    func pageIsTheColumnPlusBothMargins() {
        #expect(
            EditorPaneGeometry.maximumImageWidth(measure: 642, bleed: 100)
                == 842
        )
        #expect(
            EditorPaneGeometry.maximumImageWidth(measure: 642, bleed: 0) == 642
        )
    }

    @Test("A picture inside the column is indented like the text around it")
    func aPictureThatFitsLinesUpWithTheProse() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        #expect(page.imageParagraphIndent(imageWidth: 300) == 100)
        #expect(page.imageParagraphIndent(imageWidth: 642) == 100)
    }

    @Test("A picture past the column gives up its indent on both sides")
    func aPictureThatOutgrowsTheColumnSpreadsSymmetrically() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        // 100 wider than the column: 50 into each margin.
        #expect(page.imageParagraphIndent(imageWidth: 742) == 50)
        // The whole page: no indent left.
        #expect(page.imageParagraphIndent(imageWidth: 842) == 0)
        // And it cannot go further, however wide the picture claims to be.
        #expect(page.imageParagraphIndent(imageWidth: 2_000) == 0)
    }

    @Test("The picture stays centred on the column as it grows")
    func growingAPictureKeepsItsCentreStill() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        let columnCentre = 100 + 642 / 2.0
        for width in stride(from: 642.0, through: 842.0, by: 25) {
            let indent = page.imageParagraphIndent(imageWidth: width)
            let centre = indent + width / 2
            #expect(abs(centre - columnCentre) < 0.001, "at width \(width)")
        }
    }

    @Test("There is no jump where the two rules meet")
    func theIndentIsContinuousAtTheColumnWidth() {
        let page = MarkdownPageMetrics(measure: 642, bleed: 100)
        let justInside = page.imageParagraphIndent(imageWidth: 641.9)
        let justOutside = page.imageParagraphIndent(imageWidth: 642.1)
        #expect(abs(justInside - justOutside) < 0.1)
    }

    @Test("With no bleed the page is the column and nothing indents")
    func aPageWithoutMarginsBehavesLikeTheOldOne() {
        let page = MarkdownPageMetrics(measure: 390, bleed: 0)
        #expect(page.maximumImageWidth == 390)
        #expect(page.imageParagraphIndent(imageWidth: 100) == 0)
        #expect(page.imageParagraphIndent(imageWidth: 390) == 0)
    }
}
