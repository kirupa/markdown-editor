import Foundation
import Testing

@testable import MarkdownEditorCore

/// Remembering what the author has already decided.
///
/// The failure that matters: a second critique produces new findings with new
/// identifiers, so without a stable name for a finding, every re-run
/// resurrects every dismissal and the feature nags at somebody who already
/// answered it.
@Suite("Critique resolutions")
struct CritiqueResolutionsTests {
    private func finding(
        quote: String,
        category: String = "Clarity and precision",
        severity: CritiqueSeverity = .medium,
        why: String = "because"
    ) -> CritiqueFinding {
        CritiqueFinding(
            severity: severity,
            category: category,
            location: "paragraph 1",
            quote: quote,
            why: why
        )
    }

    @Test("A decision survives a critique that returns different identifiers")
    func aDismissalSurvivesARerun() {
        // Every finding gets a fresh UUID, so identity cannot come from there.
        var resolutions = CritiqueResolutions()
        let first = finding(quote: "Studies show it improves by 90%.")
        resolutions.set(.dismissed, for: first)

        let second = finding(quote: "Studies show it improves by 90%.")
        #expect(first.id != second.id, "a re-run really does renumber")
        #expect(resolutions.resolution(for: second) == .dismissed)
    }

    @Test("A model that retypes the passage does not escape the decision")
    func foldingMeansRetypingIsNotANewFinding() {
        // Straight quotes for curly, a wrapped line become a space: the same
        // objection to the same sentence, and it must not come back.
        var resolutions = CritiqueResolutions()
        resolutions.set(
            .completed,
            for: finding(quote: "He said \u{201C}it\u{2019}s fine\u{201D} and\nleft.")
        )
        #expect(
            resolutions.resolution(
                for: finding(quote: "He said \"it's fine\" and left.")
            ) == .completed
        )
    }

    @Test("Two objections to one sentence are two decisions")
    func categoryIsPartOfTheName() {
        // Dismissing the grammar note must not silence the credibility note
        // about the same words.
        var resolutions = CritiqueResolutions()
        let grammar = finding(quote: "it own tradeoffs", category: "Grammar and mechanics")
        let credibility = finding(quote: "it own tradeoffs", category: "Logic and credibility")
        resolutions.set(.dismissed, for: grammar)

        #expect(resolutions.resolution(for: grammar) == .dismissed)
        #expect(resolutions.resolution(for: credibility) == nil)
    }

    @Test("A rephrased explanation is still the same finding")
    func wordingAndSeverityAreNotPartOfTheName() {
        // Both vary between runs for the same underlying problem. A name that
        // changed when the model rephrased itself would not survive the thing
        // it exists to survive.
        var resolutions = CritiqueResolutions()
        resolutions.set(
            .dismissed,
            for: finding(quote: "a claim", severity: .high, why: "No citation.")
        )
        #expect(
            resolutions.resolution(
                for: finding(quote: "a claim", severity: .low, why: "This needs a source.")
            ) == .dismissed
        )
    }

    @Test("A decision can be taken back")
    func aResolutionCanBeCleared() {
        var resolutions = CritiqueResolutions()
        let one = finding(quote: "a claim")
        resolutions.set(.dismissed, for: one)
        resolutions.set(nil, for: one)
        #expect(resolutions.resolution(for: one) == nil)
        #expect(resolutions.isEmpty)
    }

    @Test("Decisions survive being written down and read back")
    func storageRoundTrips() {
        var resolutions = CritiqueResolutions()
        resolutions.set(.completed, for: finding(quote: "one"))
        resolutions.set(.dismissed, for: finding(quote: "two"))

        let reloaded = CritiqueResolutions(storage: resolutions.storage)
        #expect(reloaded == resolutions)
        #expect(reloaded.count == 2)
    }

    @Test("A value written by a newer build is ignored, not fatal")
    func unknownStoredValuesAreDropped() {
        let reloaded = CritiqueResolutions(storage: ["a": "completed", "b": "deferred"])
        #expect(reloaded.count == 1)
    }

    @Test("A dismissal about text that no longer exists is forgotten")
    func pruningDropsDeadDismissals() {
        // The author rewrote the sentence, so nothing will ever fingerprint to
        // it again. Keeping it means the store grows forever with decisions
        // about text that is gone.
        var resolutions = CritiqueResolutions()
        let gone = finding(quote: "a sentence since rewritten")
        let alive = finding(quote: "a sentence still there")
        resolutions.set(.dismissed, for: gone)
        resolutions.set(.dismissed, for: alive)

        resolutions.prune(keeping: [alive])
        #expect(resolutions.resolution(for: alive) == .dismissed)
        #expect(resolutions.resolution(for: gone) == nil)
    }

    @Test("Something marked done is remembered even once it stops being raised")
    func pruningKeepsCompletions() {
        // Absence is the expected outcome of fixing something and re-running.
        // Dropping it then would mean a later run that raises the issue again
        // arrives as though it were new.
        var resolutions = CritiqueResolutions()
        let fixed = finding(quote: "a sentence since fixed")
        resolutions.set(.completed, for: fixed)

        resolutions.prune(keeping: [])
        #expect(resolutions.resolution(for: fixed) == .completed)
    }
}
