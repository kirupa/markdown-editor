import CoreGraphics
import Testing
@testable import MarkdownEditorUI

@Suite("Double-clicking the title bar")
struct TitleBarFillTests {
    /// A laptop's visible frame: the menu bar off the top, the Dock off the
    /// bottom, in AppKit's bottom-up screen coordinates.
    private let screen = CGRect(x: 0, y: 80, width: 1_512, height: 865)
    private let window = CGRect(x: 228, y: 105, width: 1_056, height: 820)
    private let fallback = CGSize(width: 1_056, height: 820)

    @Test("A double-click fills all the available space")
    func fillsTheScreen() {
        var fill = TitleBarFill()
        #expect(
            fill.toggle(from: window, available: screen, fallbackSize: fallback)
                == screen
        )
    }

    @Test("A second double-click puts the window back exactly where it was")
    func secondDoubleClickRestores() {
        var fill = TitleBarFill()
        let filled = fill.toggle(
            from: window, available: screen, fallbackSize: fallback
        )
        #expect(
            fill.toggle(from: filled, available: screen, fallbackSize: fallback)
                == window
        )
        // And the one after that fills again, so the gesture keeps toggling.
        #expect(
            fill.toggle(from: window, available: screen, fallbackSize: fallback)
                == screen
        )
    }

    @Test("A window that settles a point off the screen's frame still counts as filled")
    func roundingDoesNotBreakTheToggle() {
        // The window server rounds to pixels. Asked for a fractional frame it
        // lands a fraction away, and that must not read as "moved since".
        var fill = TitleBarFill()
        _ = fill.toggle(from: window, available: screen, fallbackSize: fallback)
        let settled = screen.insetBy(dx: 0.5, dy: 0.5)
        fill.settle(at: settled)
        #expect(
            fill.toggle(from: settled, available: screen, fallbackSize: fallback)
                == window
        )
    }

    @Test("A frame read before the resize landed cannot become the filled one")
    func settlingOnTheOldFrameIsIgnored() {
        var fill = TitleBarFill()
        _ = fill.toggle(from: window, available: screen, fallbackSize: fallback)
        fill.settle(at: window)
        #expect(fill.filledFrame == screen)
    }

    @Test("Resizing a filled window by hand starts the toggle again")
    func movingAfterFillingForgetsTheEarlierFrame() {
        var fill = TitleBarFill()
        _ = fill.toggle(from: window, available: screen, fallbackSize: fallback)
        // Dragged smaller from the corner. Going back from here to a frame
        // chosen before the drag would undo the reader's own resize.
        let resized = CGRect(x: 0, y: 300, width: 1_200, height: 645)
        #expect(
            fill.toggle(from: resized, available: screen, fallbackSize: fallback)
                == screen
        )
        #expect(
            fill.toggle(from: screen, available: screen, fallbackSize: fallback)
                == resized
        )
    }

    @Test("A window already filling with nothing to go back to shrinks to the default size")
    func alreadyFullWithNoMemoryGoesToTheDefault() {
        // Restored at full size after a relaunch: the earlier frame was never
        // seen, and doing nothing would leave the gesture dead on the window
        // it is most wanted on.
        var fill = TitleBarFill()
        let target = fill.toggle(
            from: screen, available: screen, fallbackSize: fallback
        )
        #expect(target.size == fallback)
        #expect(target.midX == screen.midX)
        #expect(target.midY == screen.midY)
        // And the next double-click fills again.
        #expect(
            fill.toggle(from: target, available: screen, fallbackSize: fallback)
                == screen
        )
    }

    @Test("Going back never produces a window off the screen or bigger than it")
    func theEarlierFrameIsFittedToASmallerScreen() {
        // Filled on a large display that has since been swapped for a laptop,
        // which macOS then filled with the window.
        let large = CGRect(x: 0, y: 0, width: 2_560, height: 1_415)

        // Somewhere the laptop does not reach: brought on, at its own size.
        var fill = TitleBarFill()
        let offLaptop = CGRect(x: 1_700, y: 300, width: 1_000, height: 700)
        _ = fill.toggle(from: offLaptop, available: large, fallbackSize: fallback)
        let brought = fill.toggle(
            from: screen, available: screen, fallbackSize: fallback
        )
        #expect(screen.contains(brought))
        #expect(brought.size == offLaptop.size)

        // Bigger than the laptop: cut down to it rather than hanging past it.
        fill = TitleBarFill()
        let huge = CGRect(x: 100, y: 100, width: 2_000, height: 1_200)
        _ = fill.toggle(from: huge, available: large, fallbackSize: fallback)
        let fitted = fill.toggle(
            from: screen, available: screen, fallbackSize: fallback
        )
        #expect(screen.contains(fitted))
        #expect(fitted.size == screen.size)
    }

    @Test("A window partly off the screen goes back exactly where it was")
    func aPartlyOffscreenFrameIsNotMoved() {
        // Hanging off the bottom is a place a person put it, not an error.
        var fill = TitleBarFill()
        let hanging = CGRect(x: 600, y: -200, width: 900, height: 700)
        _ = fill.toggle(from: hanging, available: screen, fallbackSize: fallback)
        #expect(
            fill.toggle(from: screen, available: screen, fallbackSize: fallback)
                == hanging
        )
    }
}
