import Testing

@testable import MarkdownEditorCore

/// The number on the rail, and the word beside it.
///
/// Both have to survive the author trying to get to a hundred without
/// improving anything: the friction review reached "100, Ready" twice that
/// way — once on an empty document, once by dismissing every note while the
/// summary still listed three problems.
@Suite("Critique score")
struct CritiqueScoreTests {
    private func finding(_ severity: CritiqueSeverity) -> CritiqueFinding {
        CritiqueFinding(
            severity: severity,
            category: "Clarity and precision",
            location: "paragraph 1",
            quote: "a passage",
            why: "because"
        )
    }

    @Test("Nothing against the draft is a hundred, and Ready")
    func clean() {
        #expect(CritiqueScore.score(for: []) == 100)
        #expect(CritiqueScore.verdict(100) == "Ready")
    }

    @Test("The decay lands where its comment says")
    func calibration() {
        #expect(CritiqueScore.score(for: [finding(.high)]) == 82)
        let messy = Array(repeating: finding(.high), count: 3)
            + Array(repeating: finding(.medium), count: 4)
        #expect(CritiqueScore.score(for: messy) == 39)
        let dire = Array(repeating: finding(.high), count: 40)
        #expect(CritiqueScore.score(for: dire) == 1, "never zero")
    }

    @Test("Problems the summary lists count as a low note each")
    func listedProblems() {
        #expect(CritiqueScore.score(for: [], listedProblems: 1) == 97)
        #expect(CritiqueScore.score(for: [], listedProblems: 3) == 90)
        #expect(
            CritiqueScore.score(for: [], listedProblems: 1)
                == CritiqueScore.score(for: [finding(.low)])
        )
        #expect(CritiqueScore.score(for: [], listedProblems: -2) == 100)
    }

    @Test("Done clears a note; dismissing it does not")
    func resolutions() {
        #expect(CritiqueScore.counts(nil))
        #expect(CritiqueScore.counts(.dismissed))
        #expect(!CritiqueScore.counts(.completed))

        let notes: [(CritiqueFinding, CritiqueResolution?)] = [
            (finding(.high), nil), (finding(.medium), nil), (finding(.low), nil),
        ]
        func score(_ answered: CritiqueResolution?) -> Int {
            CritiqueScore.score(
                for: notes
                    .map { ($0.0, answered) }
                    .filter { CritiqueScore.counts($0.1) }
                    .map(\.0)
            )
        }
        #expect(score(.dismissed) == score(nil), "dismissing everything changes nothing")
        #expect(score(.completed) == 100)
    }

    @Test("A hundred is Ready only when a critique of the text as it is says so")
    func confirmation() {
        #expect(CritiqueScore.verdict(100, isConfirmed: true) == "Ready")
        #expect(CritiqueScore.verdict(100, isConfirmed: false) == "Looks ready")
        // Below a hundred the bands do not depend on it.
        #expect(CritiqueScore.verdict(90, isConfirmed: false) == "Nearly there")
        #expect(CritiqueScore.verdict(85) == "Nearly there")
        #expect(CritiqueScore.verdict(84) == "Solid, with work to do")
        #expect(CritiqueScore.verdict(60) == "Solid, with work to do")
        #expect(CritiqueScore.verdict(59) == "Needs a pass")
        #expect(CritiqueScore.verdict(35) == "Needs a pass")
        #expect(CritiqueScore.verdict(34) == "Needs a rewrite")
    }

    @Test("A draft too short to critique is caught before it is sent")
    func shortfall() {
        #expect(CritiqueRequest.shortfall(in: "# ") == 0)
        #expect(CritiqueRequest.shortfall(in: "# Title\n\nOne short line.") == 4)
        let enough = Array(repeating: "word", count: CritiqueRequest.minimumProseWords)
            .joined(separator: " ")
        #expect(CritiqueRequest.shortfall(in: enough) == nil)
        // Code is not prose, however much of it there is.
        let code = "```\n" + String(repeating: "let x = 1\n", count: 50) + "```\n"
        #expect(CritiqueRequest.shortfall(in: code) == 0)
    }
}
