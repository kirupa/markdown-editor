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
            CritiqueHighlightState.of(
                finding,
                selected: UUID(),
                hovered: UUID()
            ) == .resting
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

    // MARK: - The three washes

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
                    // existed.
                    #expect(wash.alpha >= 0.15)
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
            }
        }
    }

    @Test("Three severities in three states are nine different washes")
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
                seen.count == 9,
                Comment(rawValue: "two washes collided in \(mode)")
            )
        }
    }
}
