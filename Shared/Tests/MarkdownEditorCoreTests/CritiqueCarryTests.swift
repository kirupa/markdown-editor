import Foundation
import Testing

@testable import MarkdownEditorCore

/// Carrying a critique's notes into the next one.
///
/// The rules here decide whether an author's work survives a re-run: which
/// notes come back, which are cleared, and what the rail says changed. Every
/// one of them was, before this, a re-run that quietly started over.
@Suite("Carrying notes into a re-run")
struct CritiqueCarryTests {
    private let draft = """
        # Caching

        Caching cut our median response time from 400ms to 20ms.

        The tradeoff is staleness, and it is genuinely hard.
        """

    private func note(
        _ quote: String,
        category: String = "Clarity and precision",
        severity: CritiqueSeverity = .medium,
        location: String = "paragraph 2"
    ) -> CritiqueFinding {
        CritiqueFinding(
            severity: severity, category: category,
            location: location, quote: quote, why: "Because."
        )
    }

    // MARK: - Verdicts

    @Test("Fixed is fixed, and keeps the note's identity")
    func fixedKeepsIdentity() {
        let finding = note("The tradeoff is staleness")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: nil), verdict: .fixed, in: draft
        )
        #expect(outcome.change == .fixed)
        #expect(outcome.finding.id == finding.id)
        #expect(outcome.isFixed)
    }

    @Test("A note marked Done that the critic confirms is fixed")
    func doneConfirmed() {
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is staleness"), resolution: .completed),
            verdict: .fixed, in: draft
        )
        #expect(outcome.change == .fixed)
    }

    @Test("A note marked Done that still applies comes back open, and says so")
    func doneReopened() {
        let finding = note("The tradeoff is staleness")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: .completed),
            verdict: .stillApplies(quote: nil, location: nil), in: draft
        )
        #expect(outcome.change == .reopened)
        #expect(outcome.resolution == nil)
        #expect(outcome.finding == finding)
    }

    @Test("A rewritten passage that still has the problem is reopened")
    func editedReopened() {
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is stale"), resolution: nil, isEdited: true),
            verdict: .stillApplies(quote: nil, location: nil), in: draft
        )
        #expect(outcome.change == .reopened)
        #expect(outcome.resolution == nil)
    }

    @Test("A dismissed note the critic still sees stays dismissed")
    func dismissedStays() {
        // Dismissing is deciding to leave the passage as it is. The critic
        // saying the passage is as it was is not news, and reopening the note
        // would be the nag dismissing exists to stop.
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is staleness"), resolution: .dismissed),
            verdict: .stillApplies(quote: nil, location: nil), in: draft
        )
        #expect(outcome.change == .unchanged)
        #expect(outcome.resolution == .dismissed)
    }

    @Test("An open note that still applies stays open")
    func openStaysOpen() {
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is staleness"), resolution: nil),
            verdict: .stillApplies(quote: nil, location: nil), in: draft
        )
        #expect(outcome.change == .stillOpen)
        #expect(outcome.resolution == nil)
    }

    @Test("Silence leaves an open note exactly as it was")
    func silenceKeeps() {
        let finding = note("The tradeoff is staleness")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: nil), verdict: nil, in: draft
        )
        #expect(outcome.change == .unchanged)
        #expect(outcome.resolution == nil)
        #expect(outcome.finding == finding)
    }

    @Test("Silence leaves a dismissed note dismissed")
    func silenceKeepsDismissal() {
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is staleness"), resolution: .dismissed),
            verdict: nil, in: draft
        )
        #expect(outcome.change == .unchanged)
        #expect(outcome.resolution == .dismissed)
    }

    @Test("Silence about a note marked Done is taken as fixed")
    func silenceAboutDoneIsFixed() {
        // A Done note waiting on a verdict holds "Ready" back. If the critic
        // leaves it out for ever, it would hold it back for ever.
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is staleness"), resolution: .completed),
            verdict: nil, in: draft
        )
        #expect(outcome.change == .fixed)
    }

    @Test("Silence about a rewritten passage is taken as fixed")
    func silenceAboutAnEditIsFixed() {
        // Otherwise a note waits for ever on an answer the model keeps
        // leaving out. If it was wrong to stay quiet, the problem comes back
        // as a new finding.
        let outcome = CritiqueCarry.resolve(
            .init(finding: note("The tradeoff is stale"), resolution: nil, isEdited: true),
            verdict: nil, in: draft
        )
        #expect(outcome.change == .fixed)
    }

    // MARK: - Where a note points afterwards

    @Test("A new quote is taken when it can be found")
    func requotes() {
        let finding = note("The tradeoff is stale")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: nil),
            verdict: .stillApplies(
                quote: "it is genuinely hard", location: "paragraph 3"
            ),
            in: draft
        )
        #expect(outcome.finding.id == finding.id)
        #expect(outcome.finding.quote == "it is genuinely hard")
        #expect(outcome.finding.location == "paragraph 3")
        #expect(outcome.finding.why == finding.why)
    }

    @Test("A new quote that is not in the draft is ignored")
    func ignoresAQuoteThatIsNotThere() {
        // Taking it would turn a working note into "Not found".
        let finding = note("The tradeoff is staleness")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: nil),
            verdict: .stillApplies(quote: "nothing like this is in the draft", location: nil),
            in: draft
        )
        #expect(outcome.finding.quote == finding.quote)
    }

    @Test("A rewritten passage is quoted as the author left it")
    func editedFallsBackToThePassage() {
        let outcome = CritiqueCarry.resolve(
            .init(
                finding: note("The tradeoff is stale"),
                resolution: nil,
                isEdited: true,
                passage: "The tradeoff is staleness, and it is genuinely hard."
            ),
            verdict: .stillApplies(quote: "not in the draft", location: nil),
            in: draft
        )
        #expect(outcome.finding.quote == "The tradeoff is staleness, and it is genuinely hard.")
    }

    @Test("Nothing new to say leaves the very same finding")
    func noChangeNoCopy() {
        let finding = note("The tradeoff is staleness")
        let outcome = CritiqueCarry.resolve(
            .init(finding: finding, resolution: nil),
            verdict: .stillApplies(quote: finding.quote, location: ""),
            in: draft
        )
        #expect(outcome.finding == finding)
    }

    // MARK: - Repeats

    @Test("The same passage under the same heading is a repeat")
    func fingerprintRepeat() {
        let carried = note("The tradeoff is staleness")
        let again = note("The tradeoff is staleness")
        #expect(CritiqueCarry.isRepeat(again, of: [carried]))
    }

    @Test("A quote inside another under the same heading is a repeat")
    func containedRepeat() {
        let carried = note("The tradeoff is staleness")
        let again = note("The tradeoff is staleness, and it is genuinely hard.")
        #expect(CritiqueCarry.isRepeat(again, of: [carried]))
    }

    @Test("A different objection to the same sentence is not a repeat")
    func otherCategoryIsNew() {
        let carried = note("The tradeoff is staleness")
        let other = note("The tradeoff is staleness", category: "Logic and credibility")
        #expect(!CritiqueCarry.isRepeat(other, of: [carried]))
    }

    @Test("A few words in common are not a repeat")
    func shortContainmentIsNew() {
        // "the" is inside most quotes.
        let carried = note("genuinely")
        let other = note("The tradeoff is genuinely hard to explain")
        #expect(!CritiqueCarry.isRepeat(other, of: [carried]))
    }

    // MARK: - The request

    @Test("Notes are named n1, n2… in order")
    func keys() {
        let notes = CritiqueCarry.previousNotes([note("one"), note("two")])
        #expect(notes.map(\.key) == ["n1", "n2"])
        #expect(notes[1].quote == "two")
    }

    // MARK: - What changed

    @Test("The summary names only what happened")
    func summary() {
        #expect(
            CritiqueCarry.Delta(fixed: 2, reopened: 0, new: 1).summary
                == "2 fixed · 1 new since the last critique."
        )
        #expect(
            CritiqueCarry.Delta(fixed: 0, reopened: 1, new: 0).summary
                == "1 reopened since the last critique."
        )
        #expect(
            CritiqueCarry.Delta(fixed: 0, reopened: 0, new: 0).summary
                == "Nothing fixed and nothing new since the last critique."
        )
    }
}

@Suite("Reading what a critique said about earlier notes")
struct CritiqueVerdictDecodingTests {
    private func answer(_ previous: String) throws -> CritiqueAnswer {
        try CritiqueReportDecoder.decodeAnswer(
            """
            {"jobRead":"","overall":"","findings":[],"previous":\(previous)}
            """
        )
    }

    @Test("The list that was asked for")
    func list() throws {
        let verdicts = try answer(
            """
            [{"id":"n1","status":"fixed"},
             {"id":"n2","status":"stillApplies","quote":"q","location":"paragraph 3"}]
            """
        ).verdicts
        #expect(verdicts["n1"] == .fixed)
        #expect(verdicts["n2"] == .stillApplies(quote: "q", location: "paragraph 3"))
    }

    @Test("A map, which a model sometimes writes instead")
    func map() throws {
        let verdicts = try answer(
            #"{"n1":"fixed","n2":{"status":"still applies","quote":"q"}}"#
        ).verdicts
        #expect(verdicts["n1"] == .fixed)
        #expect(verdicts["n2"] == .stillApplies(quote: "q", location: nil))
    }

    @Test("Names in whatever shape they come back")
    func keysNormalised() throws {
        let verdicts = try answer(
            #"[{"id":" N1 ","status":"Fixed"},{"id":2,"status":"resolved"},{"id":"3","status":"STILL_APPLIES"}]"#
        ).verdicts
        #expect(verdicts["n1"] == .fixed)
        #expect(verdicts["n2"] == .fixed)
        #expect(verdicts["n3"] == .stillApplies(quote: nil, location: nil))
    }

    @Test("A verdict that cannot be read is left out, not fatal")
    func unreadableSkipped() throws {
        let answer = try answer(
            #"[{"id":"n1","status":"maybe"},{"status":"fixed"},{"id":"n2","status":"fixed"}]"#
        )
        #expect(answer.verdicts == ["n2": .fixed])
    }

    @Test("A reply with no verdicts is still a report")
    func none() throws {
        let answer = try CritiqueReportDecoder.decodeAnswer(
            #"{"jobRead":"Readers.","overall":"Fine.","findings":[]}"#
        )
        #expect(answer.verdicts.isEmpty)
        #expect(answer.report.jobRead == "Readers.")
    }
}

@Suite("Asking about earlier notes")
struct CritiquePreviousPromptTests {
    private let draft = "The tradeoff is staleness."

    @Test("Notes go after the draft, fenced, with the field to answer in")
    func carried() throws {
        let prompt = CritiqueRequest.prompt(
            forDocument: draft,
            skill: nil,
            previous: [
                CritiquePreviousNote(
                    key: "n1", category: "Clarity and precision",
                    location: "paragraph 1", quote: "The tradeoff", why: "Vague."
                )
            ]
        )
        let draftEnd = try #require(prompt.range(of: "DRAFT>>>")).upperBound
        let notes = try #require(prompt.range(of: "<<<EARLIER NOTES"))
        #expect(notes.lowerBound > draftEnd)
        #expect(prompt.contains(#""id" : "n1""#))
        #expect(prompt.contains(#""previous": [{ "id": "n1""#))
        #expect(prompt.contains("Do not repeat these notes"))
    }

    @Test("Without notes the request is as it was")
    func notCarried() {
        let prompt = CritiqueRequest.prompt(forDocument: draft, skill: nil)
        #expect(!prompt.contains("EARLIER NOTES"))
        #expect(!prompt.contains(#""previous""#))
    }
}

@Suite("Saving what a critique found fixed")
struct CritiqueRevisionFixedTests {
    private let report = CritiqueReport(jobRead: "", overall: "", findings: [])
    private let fixed = CritiqueFinding(
        severity: .high, category: "Logic and credibility",
        location: "paragraph 2", quote: "90%", why: "No source."
    )

    @Test("Fixed notes round-trip, and do not count against the score")
    func roundTrip() throws {
        let revision = CritiqueRevision(report: report, documentText: "x", fixed: [fixed])
        let data = try JSONEncoder().encode(revision)
        let back = try JSONDecoder().decode(CritiqueRevision.self, from: data)
        #expect(back == revision)
        #expect(back.fixed == [fixed])
        #expect(back.score == 100)
    }

    @Test("None is not written at all")
    func noneOmitted() throws {
        // So a build that has never heard of the field reads the file the same.
        let revision = CritiqueRevision(report: report, documentText: "x")
        #expect(revision.fixed == nil)
        let json = String(decoding: try JSONEncoder().encode(revision), as: UTF8.self)
        #expect(!json.contains("fixed"))
    }

    @Test("A history written before the field existed still loads")
    func olderHistoryLoads() throws {
        let older = try JSONEncoder().encode(CritiqueRevision(report: report, documentText: "x"))
        let back = try JSONDecoder().decode(CritiqueRevision.self, from: older)
        #expect(back.fixed == nil)
        #expect(back.documentText == "x")
    }
}
