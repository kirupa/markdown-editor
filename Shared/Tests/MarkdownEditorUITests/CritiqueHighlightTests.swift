import Foundation
import MarkdownEditorCore
import Testing

@testable import MarkdownEditorUI

/// The rail and the text are two views of one selection, and now of one
/// pointer as well. Which wash a passage is drawn in is decided from two
/// identifiers, and it is decided here rather than at each platform's call
/// site so the three builds cannot answer it differently.
@Suite("Critique highlight")
struct CritiqueHighlightTests {
    private let everyMode = EditorAppearanceMode.allCases
    private let everySeverity = CritiqueSeverity.allCases

    // MARK: - Which state a passage is in

    @Test("A finding nobody is pointing at or reading is at rest")
    func untouchedFindingsRest() {
        let finding = UUID()

        #expect(
            CritiqueHighlightState.of(finding, selected: nil, hovered: nil)
                == .resting
        )
        #expect(
            CritiqueHighlightState.of(finding, selected: nil, hovered: UUID())
                == .resting
        )
    }

    @Test("While another note is open, the rest step back")
    func othersRecedeWhileOneIsOpen() {
        let finding = UUID()

        // Quieter rather than gone: hiding them loses the map of what else
        // the critique said, and the press that raises a neighbour's note.
        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: UUID(),
                hovered: nil
            ) == .receded
        )
        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: UUID(),
                hovered: UUID()
            ) == .receded
        )
    }

    @Test("The hovered finding answers the pointer")
    func hoveredFindingIsHovered() {
        let finding = UUID()

        #expect(
            CritiqueHighlightState.of(finding, selected: nil, hovered: finding)
                == .hovered
        )
        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: UUID(),
                hovered: finding
            ) == .hovered
        )
    }

    @Test("Selection wins over hover on the same finding")
    func selectionOutranksHover() {
        let finding = UUID()

        // The reader whose pointer is resting on the note they have already
        // opened is looking at one thing, not two. Dropping the passage back
        // to the weaker wash reads as the selection being lost.
        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: finding,
                hovered: finding
            ) == .selected
        )
    }

    // MARK: - The four washes

    @Test("Hover sits between resting and selected, on every severity and mode")
    func hoverSitsBetween() throws {
        for severity in everySeverity {
            for mode in everyMode {
                let resting = try #require(
                    severity.highlight(on: mode).sRGBComponents
                )
                let hovered = try #require(
                    severity.hoveredHighlight(on: mode).sRGBComponents
                )
                let selected = try #require(
                    severity.selectedHighlight(on: mode).sRGBComponents
                )

                let pair = Comment(rawValue: "\(severity) on \(mode)")
                // Nothing happens when the pointer arrives.
                #expect(resting.alpha < hovered.alpha, pair)
                // The press that follows a hover looks like it did nothing.
                #expect(hovered.alpha < selected.alpha, pair)
                // Far enough apart to be seen. A step of a hundredth of an
                // alpha is a difference only a test can find.
                #expect(hovered.alpha - resting.alpha >= 0.04)
                #expect(selected.alpha - hovered.alpha >= 0.04)
            }
        }
    }

    @Test("The hover keeps the resting mark's own colour")
    func hoverKeepsTheHue() throws {
        for severity in everySeverity {
            for mode in everyMode {
                let resting = try #require(
                    severity.highlight(on: mode).sRGBComponents
                )
                let hovered = try #require(
                    severity.hoveredHighlight(on: mode).sRGBComponents
                )

                // More of the mark already there, not a different mark: the
                // note has not changed its mind about the sentence, the
                // pointer has arrived.
                #expect(abs(resting.red - hovered.red) < 0.001)
                #expect(abs(resting.green - hovered.green) < 0.001)
                #expect(abs(resting.blue - hovered.blue) < 0.001)
            }
        }
    }

    @Test("Every wash is visible on the page it is drawn on")
    func everyWashIsVisible() throws {
        for severity in everySeverity {
            for mode in everyMode {
                for state in CritiqueHighlightState.allCases {
                    let wash = try #require(
                        severity.highlight(state, on: mode).sRGBComponents
                    )
                    // A wash darker than nothing is no wash at all — the red
                    // measured 1.11:1 against a dark page before the dark set
                    // existed. The receded wash is meant to be under this,
                    // and has a floor of its own below.
                    if state != .receded {
                        #expect(wash.alpha >= 0.15)
                    }
                    // And one strong enough to fight the words under it is not
                    // a highlight either.
                    #expect(wash.alpha <= 0.45)
                }
            }
        }
    }

    @Test("Asking by state gives the same colour as asking by name")
    func stateAndNameAgree() {
        for severity in everySeverity {
            for mode in everyMode {
                #expect(
                    severity.highlight(.resting, on: mode)
                        == severity.highlight(on: mode)
                )
                #expect(
                    severity.highlight(.hovered, on: mode)
                        == severity.hoveredHighlight(on: mode)
                )
                #expect(
                    severity.highlight(.selected, on: mode)
                        == severity.selectedHighlight(on: mode)
                )
                #expect(
                    severity.highlight(.receded, on: mode)
                        == severity.recededHighlight(on: mode)
                )
            }
        }
    }

    @Test("Three severities in four states are twelve different washes")
    func everyWashIsDistinct() {
        for mode in everyMode {
            var seen: Set<String> = []
            for severity in everySeverity {
                for state in CritiqueHighlightState.allCases {
                    let wash = severity.highlight(state, on: mode)
                    let components = wash.sRGBComponents!
                    seen.insert(
                        "\(components.red),\(components.green),"
                            + "\(components.blue),\(components.alpha)"
                    )
                }
            }
            #expect(
                seen.count == 12,
                Comment(rawValue: "two washes collided in \(mode)")
            )
        }
    }

    @Test("A receded wash is a step under resting, in the same colour")
    func recededSitsUnderResting() throws {
        for severity in everySeverity {
            for mode in everyMode {
                let resting = try #require(
                    severity.highlight(on: mode).sRGBComponents
                )
                let receded = try #require(
                    severity.recededHighlight(on: mode).sRGBComponents
                )
                let pair = Comment(rawValue: "\(severity) on \(mode)")
                #expect(receded.alpha < resting.alpha, pair)
                // The same mark with less of it, not a different mark.
                #expect(abs(resting.red - receded.red) < 0.001, pair)
                #expect(abs(resting.green - receded.green) < 0.001, pair)
                #expect(abs(resting.blue - receded.blue) < 0.001, pair)
            }
        }
    }

    @Test("A receded wash can still be seen, and seen to have stepped back")
    func recededIsVisible() throws {
        // Judged in CIELAB rather than by alpha, because how much a tint
        // shows depends on its hue: the low-severity blue at 0.09 on white
        // is ΔE 5.0 from the page, the red at the same alpha 7.1. ΔE 2.3 is
        // about the smallest difference anyone can see; these ask for twice
        // that from the page, so there is still a mark to press, and more
        // than it from the resting wash, so opening a note visibly changes
        // the ones around it.
        for (mode, page) in [
            (EditorAppearanceMode.light, 1.0), (.dark, 0.13)
        ] {
            for severity in everySeverity {
                let resting = try #require(
                    severity.highlight(on: mode).sRGBComponents
                )
                let receded = try #require(
                    severity.recededHighlight(on: mode).sRGBComponents
                )
                let paper = Lab(red: page, green: page, blue: page)
                let atRest = Lab(resting, over: page)
                let stepped = Lab(receded, over: page)
                let pair = Comment(rawValue: "\(severity) on \(mode)")
                #expect(stepped.distance(to: paper) >= 4.6, pair)
                #expect(atRest.distance(to: stepped) >= 3, pair)
            }
        }
    }

    @Test("Selection and hover both outrank receding")
    func recededNeverWins() {
        let finding = UUID()
        let other = UUID()

        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: finding,
                hovered: other
            ) == .selected
        )
        // Pointing at a note is asking where its passage is, whichever note
        // happens to be open.
        #expect(
            CritiqueHighlightState.of(
                finding,
                selected: other,
                hovered: finding
            ) == .hovered
        )
    }

    // MARK: - The rule under the open note's passage

    @Test("Only the open note's passage is ruled")
    func onlySelectionIsRuled() {
        for severity in everySeverity {
            for mode in everyMode {
                // Hover deliberately does not get one. The reader asked a
                // question by pointing and answered it by pressing, and the
                // two answers have to look different.
                #expect(severity.selectionRule(.resting, on: mode) == nil)
                #expect(severity.selectionRule(.hovered, on: mode) == nil)
                #expect(severity.selectionRule(.receded, on: mode) == nil)
                #expect(
                    severity.selectionRule(.selected, on: mode)
                        == severity.selectionRule(on: mode)
                )
            }
        }
    }

    @Test("The rule is solid, not another wash")
    func theRuleIsSolid() throws {
        for severity in everySeverity {
            for mode in everyMode {
                let rule = try #require(
                    severity.selectionRule(on: mode).sRGBComponents
                )
                // The whole point is that it is not a few hundredths of an
                // alpha under text. A translucent rule is a fourth wash.
                #expect(rule.alpha == 1)
            }
        }
    }

    @Test("The rule carries the severity, the way the open note's border does")
    func theRuleCarriesTheSeverity() throws {
        for mode in everyMode {
            var seen: Set<String> = []
            for severity in everySeverity {
                let rule = try #require(
                    severity.selectionRule(on: mode).sRGBComponents
                )
                seen.insert("\(rule.red),\(rule.green),\(rule.blue)")

                // And it belongs to the same hue family as the wash it is
                // drawn under, or the passage reads as two marks rather than
                // one. Compared by which channel leads, which is what "the
                // red one" and "the blue one" actually mean.
                let wash = try #require(
                    severity.highlight(on: mode).sRGBComponents
                )
                #expect(
                    (rule.red > rule.blue) == (wash.red > wash.blue),
                    Comment(rawValue: "\(severity) on \(mode)")
                )
            }
            #expect(seen.count == 3, "two severities are ruled the same")
        }
    }

    @Test("The rule is visible on the page it is drawn on")
    func theRuleIsVisibleOnItsPage() throws {
        for (mode, page) in [
            (EditorAppearanceMode.light, 1.0), (.dark, 0.13)
        ] {
            for severity in everySeverity {
                let rule = try #require(
                    severity.selectionRule(on: mode).sRGBComponents
                )
                let luminance = 0.2126 * rule.red + 0.7152 * rule.green
                    + 0.0722 * rule.blue
                // Not a text-contrast threshold — a 2pt rule is not being
                // read. It has to be far enough from the page to be seen as a
                // line somebody drew rather than as an artefact.
                #expect(
                    abs(luminance - page) > 0.2,
                    Comment(rawValue: "\(severity) on \(mode) page")
                )
            }
        }
    }
}

/// A colour in CIELAB (D65), which is where "can this be seen" is a distance.
private struct Lab {
    let l: Double
    let a: Double
    let b: Double

    init(red: Double, green: Double, blue: Double) {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, bl) = (linear(red), linear(green), linear(blue))
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
        func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0
        }
        l = 116 * f(y) - 16
        a = 500 * (f(x) - f(y))
        b = 200 * (f(y) - f(z))
    }

    /// A translucent wash as it comes out over a grey page.
    init(
        _ wash: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat),
        over page: Double
    ) {
        let alpha = Double(wash.alpha)
        func over(_ c: CGFloat) -> Double { page * (1 - alpha) + Double(c) * alpha }
        self.init(red: over(wash.red), green: over(wash.green), blue: over(wash.blue))
    }

    /// ΔE*76.
    func distance(to other: Lab) -> Double {
        ((l - other.l) * (l - other.l) + (a - other.a) * (a - other.a)
            + (b - other.b) * (b - other.b)).squareRoot()
    }
}

/// Neighbouring notes used to run together: the air each box is given past
/// its glyphs overlapped the next passage's by 2pt, in the same colour, and a
/// reader saw one mark where the critique had made two.
@Suite("Critique highlight separation")
struct CritiqueHighlightSeparationTests {
    /// The boxes measured in a 700pt column for "Caching is important." and
    /// the sentence after it, on one line.
    private let firstSentence = CGRect(x: 26.0, y: 91, width: 151.9, height: 22)
    private let secondSentence = CGRect(x: 175.9, y: 91, width: 300, height: 22)

    private func gapBetween(_ left: CGRect, _ right: CGRect) -> CGFloat {
        right.minX - left.maxX
    }

    @Test("Two sentences side by side stop short of each other")
    func sideBySideSplit() {
        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 21), [firstSentence]),
            (NSRange(location: 22, length: 40), [secondSentence]),
        ])

        #expect(drawn.count == 2)
        let left = drawn[0][0]
        let right = drawn[1][0]
        #expect(!left.intersects(right))
        #expect(abs(gapBetween(left, right) - CritiqueHighlightLayout.separation) < 0.001)
        // Split in the space between them, not taken out of one side.
        #expect(abs((firstSentence.maxX - left.maxX) - (right.minX - secondSentence.minX)) < 0.001)
        // Only the facing edges move.
        #expect(left.minX == firstSentence.minX)
        #expect(left.minY == firstSentence.minY && left.maxY == firstSentence.maxY)
        #expect(right.maxX == secondSentence.maxX)
    }

    @Test("A passage ending above another's start gives way in the leading")
    func lineOverLineSplit() {
        // Lines measured 91–113 and 111–133: 2pt of overlap, which is the
        // double-strength stripe that joined the two.
        let upper = CGRect(x: 26, y: 91, width: 400, height: 22)
        let lower = CGRect(x: 26, y: 111, width: 300, height: 22)

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 60), [upper]),
            (NSRange(location: 61, length: 40), [lower]),
        ])

        #expect(drawn[0][0].maxY == 111)
        #expect(drawn[1][0].minY == 113)
        #expect(drawn[0][0].minY == upper.minY)
        #expect(drawn[1][0].maxY == lower.maxY)
        #expect(drawn[0][0].width == upper.width)
    }

    @Test("A passage's own lines are left touching")
    func ownLinesAreUntouched() {
        let lines = [
            CGRect(x: 26, y: 91, width: 640, height: 22),
            CGRect(x: 26, y: 111, width: 640, height: 22),
            CGRect(x: 26, y: 131, width: 371, height: 20),
        ]

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 200), lines),
        ])

        // Filled as one shape by the caller, so the overlap is not a stripe.
        #expect(drawn == [lines])
    }

    @Test("A passage inside another is drawn over it, not cut out of it")
    func nestedPassagesAreLeftAlone() {
        let paragraph = CGRect(x: 26, y: 91, width: 640, height: 22)
        let sentence = CGRect(x: 175.9, y: 91, width: 300, height: 22)

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 100), [paragraph]),
            (NSRange(location: 22, length: 40), [sentence]),
        ])

        #expect(drawn == [[paragraph], [sentence]])
    }

    @Test("Passages that share a word are left alone too")
    func overlappingPassagesAreLeftAlone() {
        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 30), [firstSentence]),
            (NSRange(location: 20, length: 40), [secondSentence]),
        ])

        #expect(drawn == [[firstSentence], [secondSentence]])
    }

    @Test("Neighbours already far enough apart are not moved")
    func distantNeighboursStay() {
        let far = CGRect(x: 300, y: 91, width: 100, height: 22)
        let below = CGRect(x: 26, y: 171, width: 100, height: 22)

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 21), [firstSentence]),
            (NSRange(location: 40, length: 10), [far]),
            (NSRange(location: 90, length: 10), [below]),
        ])

        #expect(drawn == [[firstSentence], [far], [below]])
    }

    @Test("A sentence between two others gives way on both sides")
    func threeInARow() {
        let left = CGRect(x: 26, y: 91, width: 100, height: 22)
        let middle = CGRect(x: 124, y: 91, width: 100, height: 22)
        let right = CGRect(x: 222, y: 91, width: 100, height: 22)

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 40, length: 10), [right]),
            (NSRange(location: 0, length: 10), [left]),
            (NSRange(location: 20, length: 10), [middle]),
        ])

        // Given out of order, answered in the order given.
        let (r, l, m) = (drawn[0][0], drawn[1][0], drawn[2][0])
        #expect(abs(gapBetween(l, m) - 2) < 0.001)
        #expect(abs(gapBetween(m, r) - 2) < 0.001)
        #expect(m.width > 0)
    }

    @Test("The answer does not depend on the order the notes arrived in")
    func orderDoesNotMatter() {
        let upper = CGRect(x: 26, y: 91, width: 640, height: 22)
        let wrapped = [
            CGRect(x: 26, y: 111, width: 640, height: 22),
            CGRect(x: 26, y: 131, width: 371, height: 20),
        ]
        let after = CGRect(x: 394.9, y: 131, width: 200, height: 20)
        let passages: [(range: NSRange, boxes: [CGRect])] = [
            (NSRange(location: 0, length: 50), [upper]),
            (NSRange(location: 51, length: 120), wrapped),
            (NSRange(location: 172, length: 30), [after]),
        ]

        let forwards = CritiqueHighlightLayout.separated(passages)
        let backwards = CritiqueHighlightLayout.separated(passages.reversed())

        #expect(forwards == Array(backwards.reversed()))
        // And the passage in the middle is still one shape: its two lines
        // still meet, though both of its neighbours were cut away from it.
        #expect(forwards[1][0].maxY >= forwards[1][1].minY)
        #expect(!forwards[1][1].intersects(forwards[2][0]))
        #expect(!forwards[0][0].intersects(forwards[1][0]))
    }

    @Test("A box with no room left keeps its size rather than vanishing")
    func squeezedBoxSurvives() {
        let left = CGRect(x: 0, y: 0, width: 10, height: 22)
        let sliver = CGRect(x: 8, y: 0, width: 3, height: 22)
        let right = CGRect(x: 9, y: 0, width: 10, height: 22)

        let drawn = CritiqueHighlightLayout.separated([
            (NSRange(location: 0, length: 1), [left]),
            (NSRange(location: 1, length: 1), [sliver]),
            (NSRange(location: 2, length: 1), [right]),
        ])

        #expect(drawn[1][0].width >= 2)
    }
}
