import CoreGraphics
import Testing
@testable import MarkdownEditorUI

/// The shape selected text is shaded in, one line at a time.
///
/// A line where the selection starts and stops is a rounded bar hugging the
/// words, its hard ends exactly on the carets either side. Where it carries on
/// to the next line the bar runs past the last word and fades out, and the
/// next line's bar fades in ahead of its first word.
@Suite("Selection highlight shape")
struct SelectionHighlightGeometryTests {
    private typealias Segment = SelectionHighlightSegment

    @Test("A selection on one line is a rounded bar exactly as wide as its words")
    func singleLine() {
        let bar = Segment.line(
            from: 100, to: 180, top: 10, bottom: 29,
            continuesFromPreviousLine: false, continuesOntoNextLine: false
        )
        #expect(bar.rect == CGRect(x: 100, y: 10, width: 80, height: 19))
        #expect(bar.fadeIn == 0)
        #expect(bar.fadeOut == 0)
        #expect(bar.cornerRadius > 3.5 && bar.cornerRadius < 5)
        #expect(bar.stops.map(\.opacity) == [1, 1])
    }

    @Test("A line the selection runs on from fades out past its last word")
    func firstLineFadesOut() {
        let bar = Segment.line(
            from: 100, to: 400, top: 0, bottom: 19,
            continuesFromPreviousLine: false, continuesOntoNextLine: true
        )
        let fade = Segment.fadeLength(forHeight: 19)
        #expect(bar.rect.minX == 100)
        #expect(bar.rect.maxX == 400 + fade)
        #expect(bar.fadeIn == 0)
        #expect(bar.fadeOut == fade)
        let stops = bar.stops
        #expect(stops.first == .init(location: 0, opacity: 1))
        #expect(stops.last == .init(location: 1, opacity: 0))
        // Full strength all the way to the last word, then easing away.
        let lastWord = (400 - bar.rect.minX) / bar.rect.width
        let lastFull = stops.last { $0.opacity == 1 }
        #expect(abs((lastFull?.location ?? 0) - lastWord) < 0.0001)
    }

    @Test("A line the selection runs on to fades in before its first word")
    func lastLineFadesIn() {
        let bar = Segment.line(
            from: 30, to: 90, top: 20, bottom: 39,
            continuesFromPreviousLine: true, continuesOntoNextLine: false
        )
        let fade = Segment.fadeLength(forHeight: 19)
        #expect(bar.rect.minX == 30 - fade)
        #expect(bar.rect.maxX == 90)
        #expect(bar.fadeIn == fade)
        #expect(bar.stops.first == .init(location: 0, opacity: 0))
        #expect(bar.stops.last == .init(location: 1, opacity: 1))
    }

    @Test("A line in the middle fades at both ends")
    func middleLineFadesBothWays() {
        let bar = Segment.line(
            from: 30, to: 400, top: 20, bottom: 39,
            continuesFromPreviousLine: true, continuesOntoNextLine: true
        )
        let stops = bar.stops
        #expect(stops.first?.opacity == 0)
        #expect(stops.last?.opacity == 0)
        #expect(stops.contains { $0.opacity == 1 })
    }

    @Test("The fade eases, and never goes backwards")
    func stopsAreOrdered() {
        for (fromPrevious, ontoNext) in [
            (false, false), (true, false), (false, true), (true, true)
        ] {
            for width: CGFloat in [0, 3, 40, 600] {
                let stops = Segment.line(
                    from: 50, to: 50 + width, top: 0, bottom: 19,
                    continuesFromPreviousLine: fromPrevious,
                    continuesOntoNextLine: ontoNext
                ).stops
                #expect(stops.first?.location == 0)
                #expect(stops.last?.location == 1)
                for (earlier, later) in zip(stops, stops.dropFirst()) {
                    #expect(earlier.location <= later.location)
                }
                #expect(stops.allSatisfy { (0...1).contains($0.opacity) })
                // Every fade has a gentle start: never a jump to half.
                if fromPrevious {
                    #expect(stops[1].opacity < 0.2)
                }
            }
        }
    }

    @Test("An empty line inside a selection still shows")
    func emptyLineShows() {
        let bar = Segment.line(
            from: 30, to: 30, top: 40, bottom: 59,
            continuesFromPreviousLine: true, continuesOntoNextLine: true
        )
        let fade = Segment.fadeLength(forHeight: 19)
        #expect(bar.rect.width > 2 * fade)
        let core = bar.rect.width - 2 * fade
        #expect(core >= 4)
        #expect(abs(core - Segment.emptyRunWidth(forHeight: 19)) < 0.0001)
    }

    @Test("A narrow run is hugged, not widened into its neighbours")
    func narrowRunIsHugged() {
        // A lone "i" at 15 points is about 3.5 points across.
        let bar = Segment.line(
            from: 50, to: 53.5, top: 0, bottom: 19,
            continuesFromPreviousLine: false, continuesOntoNextLine: false
        )
        #expect(bar.rect.minX == 50)
        #expect(bar.rect.maxX == 53.5)
        #expect(bar.cornerRadius <= 1.75)
    }

    @Test("A selection that starts on a line's break starts at its caret")
    func breakStartsAtItsCaret() {
        let bar = Segment.line(
            from: 212.5, to: 212.5, top: 0, bottom: 19,
            continuesFromPreviousLine: false, continuesOntoNextLine: true
        )
        let fade = Segment.fadeLength(forHeight: 19)
        #expect(bar.rect.minX == 212.5)
        let sliver = Segment.emptyRunWidth(forHeight: 19)
        #expect(abs(bar.rect.maxX - (212.5 + sliver + fade)) < 0.0001)
    }

    @Test("Hard ends stand on their carets, for any run and any line")
    func hardEndsAreExact() {
        for height: CGFloat in [12, 19, 24.5, 40] {
            for (start, end): (CGFloat, CGFloat) in [
                (0, 0.5), (10, 13.25), (180, 100), (7.75, 640.125)
            ] {
                let bar = Segment.line(
                    from: start, to: end, top: 0, bottom: height,
                    continuesFromPreviousLine: false, continuesOntoNextLine: false
                )
                #expect(bar.rect.minX == min(start, end))
                #expect(bar.rect.maxX == max(start, end))
            }
        }
    }

    @Test("Taller lines are rounded more, to a limit; short ones stay bars")
    func cornersFollowTheLine() {
        #expect(Segment.cornerRadius(forHeight: 19) < Segment.cornerRadius(forHeight: 24))
        // Softened, but still a bar: well under a quarter of the line.
        #expect(Segment.cornerRadius(forHeight: 19) < 19 / 4)
        #expect(Segment.cornerRadius(forHeight: 60) == 6)
        let narrow = Segment.line(
            from: 10, to: 11, top: 0, bottom: 40,
            continuesFromPreviousLine: false, continuesOntoNextLine: false
        )
        #expect(narrow.cornerRadius <= narrow.rect.width / 2)
        #expect(narrow.cornerRadius <= narrow.rect.height / 2)
    }

    @Test("The fade is about a line long, but stays out of the margin")
    func fadeLengthIsBounded() {
        #expect(Segment.fadeLength(forHeight: 4) == 10)
        #expect(Segment.fadeLength(forHeight: 19) > 12)
        #expect(Segment.fadeLength(forHeight: 19) < 16)
        #expect(Segment.fadeLength(forHeight: 90) == 24)
    }
}
