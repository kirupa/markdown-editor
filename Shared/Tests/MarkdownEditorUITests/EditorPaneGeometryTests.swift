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

    // MARK: - A rail in the document's margin

    @Test("The document and its comments are centred together, not the document alone")
    func theDocumentAndRailAreCentredAsOneBlock() {
        // 1600 wide, 700 of document, 320 of rail: 1020 of content, so 290 of
        // margin each side.
        let inset = EditorPaneGeometry.documentInsetWithRail(
            documentWidth: 700, railWidth: 320, totalWidth: 1_600
        )
        #expect(inset == 290)
        // Stated as the thing that was actually wrong: the space left of the
        // writing equals the space right of the notes. Centring the document
        // alone gave 450 and 130, which reads as the whole block shoved right.
        let trailing = 1_600 - inset - 700 - 320
        #expect(inset == trailing)
    }

    @Test("The balance holds at any window width that fits both")
    func balancedAtEveryWidth() {
        for total in [CGFloat(1_100), 1_200, 1_600, 2_000, 2_560] {
            let inset = EditorPaneGeometry.documentInsetWithRail(
                documentWidth: 700, railWidth: 320, totalWidth: total
            )
            let trailing = total - inset - 700 - 320
            #expect(
                abs(inset - trailing) < 0.5,
                "at \(total) the block sits \(inset) from the left and \(trailing) from the right"
            )
        }
    }

    @Test("A window too narrow for both puts the document at the leading edge")
    func aVeryNarrowWindowDoesNotGoNegative() {
        // Below 1020 there is no arrangement that fits both, so the document
        // starts at the leading edge and the rail takes what is left.
        #expect(
            EditorPaneGeometry.documentInsetWithRail(
                documentWidth: 700, railWidth: 320, totalWidth: 1_000
            ) == 0
        )
        #expect(
            EditorPaneGeometry.documentInsetWithRail(
                documentWidth: 700, railWidth: 320, totalWidth: 800
            ) == 0
        )
    }

    @Test("With no rail the document is centred as before")
    func aRailOfNothingChangesNothing() {
        #expect(
            EditorPaneGeometry.documentInsetWithRail(
                documentWidth: 700, railWidth: 0, totalWidth: 1_600
            ) == EditorPaneGeometry.centeringInset(measure: 700, totalWidth: 1_600)
        )
    }

    // MARK: - Where the page ends when the comments are open

    @Test("A picture may spread into the margins while the comments are shut")
    func bleedsWithoutTheRail() {
        #expect(
            EditorPaneGeometry.imageBleed(
                around: 700, within: 1_600, railIsOpen: false
            ) == EditorPaneGeometry.imageBleed(around: 700, within: 1_600)
        )
        #expect(
            EditorPaneGeometry.imageBleed(
                around: 700, within: 1_600, railIsOpen: false
            ) > 0
        )
    }

    @Test("With the comments open there is no margin to spread into")
    func noBleedWithTheRail() {
        // The right-hand margin is where the notes are. Bleeding on the left
        // alone would set every wide picture off-centre against its own text,
        // and a page that ends past its column puts a second faint rule and a
        // strip of empty page between the writing and the notes about it.
        #expect(
            EditorPaneGeometry.imageBleed(
                around: 700, within: 1_600, railIsOpen: true
            ) == 0
        )
    }

    // MARK: - What the window should zoom to

    @Test("Zooming with the comments open makes room for them")
    func idealWidthCountsTheRail() {
        #expect(
            EditorPaneGeometry.idealContentWidth(
                columnWidth: 700, railWidth: 356, railIsOpen: true
            ) == 1_056
        )
    }

    @Test("Zooming with the comments shut leaves the page its bleed margins")
    func idealWidthKeepsTheBleed() {
        // Not the column alone: the bleed is the room a wide picture is
        // allowed to spread into, so zooming to 700 would leave every
        // full-page picture in the document with nowhere to go.
        #expect(
            EditorPaneGeometry.idealContentWidth(
                columnWidth: 700, railWidth: 356, railIsOpen: false
            ) == 700 + 2 * EditorPaneGeometry.maximumImageBleed
        )
    }

    @Test("Opening the comments always asks for a wider window")
    func openingTheRailNeverShrinksTheTarget() {
        // Stated as the property rather than as two numbers, because the
        // numbers are tunable and this is the part that must hold: the rail is
        // 356 wide against 200 of bleed, so it cannot be paid for out of the
        // margins the page gives up.
        for column in [CGFloat(360), 520, 700, 900, 1_100] {
            let shut = EditorPaneGeometry.idealContentWidth(
                columnWidth: column, railWidth: 356, railIsOpen: false
            )
            let open = EditorPaneGeometry.idealContentWidth(
                columnWidth: column, railWidth: 356, railIsOpen: true
            )
            #expect(open > shut, "at a column of \(column)")
        }
    }

    @Test("The zoom target grows with the column, at every width")
    func idealWidthFollowsTheColumn() {
        var previous: CGFloat = 0
        for column in [CGFloat(360), 520, 700, 900, 1_100] {
            let width = EditorPaneGeometry.idealContentWidth(
                columnWidth: column, railWidth: 356, railIsOpen: true
            )
            #expect(width > previous)
            previous = width
        }
    }

    // MARK: - What a window opens at

    /// The app's own numbers: a 700pt column, a 356pt rail, a 620×520 floor.
    private func defaultWindowSize(
        onScreenOf available: CGSize,
        railIsOpen: Bool = true
    ) -> CGSize {
        EditorPaneGeometry.defaultWindowContentSize(
            ideal: CGSize(
                width: EditorPaneGeometry.idealContentWidth(
                    columnWidth: 700, railWidth: 356, railIsOpen: railIsOpen
                ),
                height: 820
            ),
            minimum: CGSize(width: 620, height: 520),
            available: available
        )
    }

    @Test("A window opens wide enough for the writing and its comments")
    func defaultSizeFitsTheRail() {
        // The whole point: the rail is open from the moment a document is, so
        // a window that opens at the column's width alone opens with the notes
        // already squeezing the writing they are about.
        let size = defaultWindowSize(
            onScreenOf: CGSize(width: 1_800, height: 1_100)
        )
        #expect(size.width == 1_056)
        #expect(size.height == 820)
    }

    @Test("A window never opens wider than the screen it lands on")
    func defaultSizeIsCappedToTheScreen() {
        let size = defaultWindowSize(
            onScreenOf: CGSize(width: 900, height: 700)
        )
        #expect(size.width == 900)
        #expect(size.height == 700)
    }

    @Test("The window's own minimum wins over a screen smaller than it")
    func defaultSizeNeverGoesUnderTheMinimum() {
        // Nothing useful is left to do on a desk this small, and a window
        // clamped under the size its content refuses to go to is worse than
        // one that overflows: the content would be squeezed either way, and
        // this way the window can at least be moved.
        let size = defaultWindowSize(
            onScreenOf: CGSize(width: 400, height: 300)
        )
        #expect(size.width == 620)
        #expect(size.height == 520)
    }

    @Test("A roomy screen changes nothing")
    func defaultSizeDoesNotGrowToFillTheScreen() {
        // Zoom is what "as much as possible" is for. Opening should be the
        // size the content asks for, on a laptop and on a 6K display alike.
        for width in [CGFloat(1_100), 1_800, 3_000, 6_016] {
            let size = defaultWindowSize(
                onScreenOf: CGSize(width: width, height: 3_384)
            )
            #expect(size.width == 1_056, "on a screen \(width) wide")
            #expect(size.height == 820)
        }
    }

    @Test("The opening width is the width the green button zooms to")
    func defaultSizeMatchesTheZoomTarget() {
        // Two names for one measurement. If these ever disagree, zooming a
        // freshly opened window would visibly resize it for no reason.
        let roomy = CGSize(width: 4_000, height: 3_000)
        #expect(
            defaultWindowSize(onScreenOf: roomy).width
                == EditorPaneGeometry.idealContentWidth(
                    columnWidth: 700, railWidth: 356, railIsOpen: true
                )
        )
    }

    // MARK: - Double-clicking the title bar

    /// The bar and its controls, at the geometry measured from the running app:
    /// a 52pt bar, the traffic lights at the left, the file explorer at 96–132,
    /// and the theme and critique buttons at 735–812.
    private let titleBar = CGRect(x: 0, y: 648, width: 820, height: 52)
    private var titleBarControls: [CGRect] {
        [
            CGRect(x: 18, y: 664, width: 16, height: 16),
            CGRect(x: 41, y: 664, width: 16, height: 16),
            CGRect(x: 64, y: 664, width: 16, height: 16),
            CGRect(x: 96, y: 648, width: 36, height: 52),
            CGRect(x: 735, y: 648, width: 40, height: 52),
            CGRect(x: 775, y: 648, width: 37, height: 52),
        ]
    }

    @Test("Double-clicking empty title bar zooms")
    func emptyTitleBarZooms() {
        #expect(
            EditorPaneGeometry.titleBarClickZooms(
                at: CGPoint(x: 440, y: 674),
                titleBar: titleBar,
                controls: titleBarControls
            )
        )
    }

    @Test("Double-clicking a toolbar button does not zoom")
    func aControlDoesNotZoom() {
        // The theme button. This is the case the first implementation got
        // wrong: it hit-tested, SwiftUI answered with the one hosting view it
        // draws the whole bar through, and the window zoomed out from under
        // the popover the button had just opened.
        for control in titleBarControls {
            #expect(
                !EditorPaneGeometry.titleBarClickZooms(
                    at: CGPoint(x: control.midX, y: control.midY),
                    titleBar: titleBar,
                    controls: titleBarControls
                ),
                "a click at \(control.midX) should not zoom"
            )
        }
    }

    @Test("The document's title is not a control, so it zooms")
    func theTitleZooms() {
        // Between the traffic lights and the explorer button is where the
        // filename is drawn, and double-clicking a window's title zooms it in
        // every other Mac application.
        #expect(
            EditorPaneGeometry.titleBarClickZooms(
                at: CGPoint(x: 200, y: 674),
                titleBar: titleBar,
                controls: titleBarControls
            )
        )
    }

    @Test("A click below the title bar is not a title bar click")
    func theDocumentDoesNotZoom() {
        #expect(
            !EditorPaneGeometry.titleBarClickZooms(
                at: CGPoint(x: 440, y: 300),
                titleBar: titleBar,
                controls: titleBarControls
            )
        )
    }

    @Test("The width gripper stays where it can be grabbed")
    func gripperIsNotBuriedUnderTheRail() {
        // Laid out ending at the page's trailing edge and then shifted, so a
        // positive shift pushes it past that edge. With the comments open that
        // is underneath the rail, which is drawn over it — and the document
        // then cannot be resized at all. This happened: removing the bleed left
        // the old `gripperWidth - bleed` shift pointing straight into the rail.
        #expect(
            EditorPaneGeometry.gripperOffset(
                gripperWidth: 12, bleed: 0, railIsOpen: true
            ) == 0
        )
        #expect(
            EditorPaneGeometry.gripperIsReachable(
                gripperWidth: 12, bleed: 0, railIsOpen: true
            )
        )
        // The shape of the bug, stated directly: the shift the closed-rail case
        // uses would not be reachable if it were applied with the rail open.
        #expect(
            EditorPaneGeometry.gripperOffset(
                gripperWidth: 12, bleed: 0, railIsOpen: false
            ) > 0
        )
    }

    @Test("So the page ends exactly where the writing does, and the rail docks there")
    func thePageEndsAtTheColumn() {
        let column: CGFloat = 700
        let bleed = EditorPaneGeometry.imageBleed(
            around: column, within: 1_600, railIsOpen: true
        )
        let page = column + 2 * bleed
        #expect(page == column)

        // And the rail's leading edge is that same point, at any width — which
        // is what "docked" means: resize the column and the notes come with it.
        for width in [CGFloat(520), 700, 900] {
            let pageWidth = width + 2 * EditorPaneGeometry.imageBleed(
                around: width, within: 1_600, railIsOpen: true
            )
            let inset = EditorPaneGeometry.documentInsetWithRail(
                documentWidth: pageWidth, railWidth: 356, totalWidth: 1_600
            )
            #expect(inset + pageWidth == inset + width)
        }
    }
}
