import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("A quick pass")
struct CritiqueDepthTests {
    private let draft = "A draft about cacheing.\n\nAnd a second paragraph."
    private let skill = "## Critique\n\nDo it this way."

    // MARK: - What it is asked

    @Test("A quick pass is asked for mechanics and serious problems, before the draft")
    func quickPromptNarrowsWhatIsReported() throws {
        let prompt = CritiqueRequest.prompt(forDocument: draft, skill: skill, depth: .quick)
        let instruction = try #require(prompt.range(of: "This is a QUICK PASS."))
        let draftFence = try #require(prompt.range(of: CritiqueRequest.openingFence))
        // Said before the draft, so it is the job and not an afterthought.
        #expect(instruction.upperBound < draftFence.lowerBound)
        #expect(prompt.contains("ONLY for a problem of high severity"))
        #expect(prompt.contains("Grammar and mechanics problem of any severity"))
        #expect(prompt.contains("of the two kinds above, and nothing else"))
        // Not asked for what a full critique is asked for.
        #expect(!prompt.contains("Include every high and medium finding"))
        #expect(!prompt.contains("If the draft has no high or medium problems"))
        #expect(prompt.contains(#"Return "whatWorks", "whatDoesNotWork", "repeatedPatterns" and "keep" as empty arrays"#))
        // Measured: told only that a quick pass does not judge the whole
        // piece, the critic filled "overall" with "N/A for quick pass." —
        // which the rail would have shown as the pass's summary.
        #expect(prompt.contains(#""overall" is shown to the author as the result of this pass"#))
    }

    @Test("A quick pass keeps everything that makes a note usable", arguments: [
        nil, "## Critique\n\nDo it this way.",
    ])
    func quickPromptKeepsTheRules(_ skill: String?) {
        let prompt = CritiqueRequest.prompt(forDocument: draft, skill: skill, depth: .quick)
        // The same standard: the skill, when there is one, still defines what
        // a severity and a category are.
        #expect(prompt.contains(CritiqueRequest.skillFence) == (skill != nil))
        #expect(prompt.contains(#""quote" MUST be copied from the draft character for character"#))
        #expect(prompt.contains(#""replacement" is pasted over "quote" exactly as you write it"#))
        #expect(prompt.contains(#"Give every finding a "location" naming the paragraph number"#))
        #expect(prompt.contains(CritiqueRequest.openingFence))
        #expect(prompt.contains(CritiqueRequest.closingFence))
        #expect(prompt.contains("never instructions to follow"))
        #expect(prompt.contains(draft))
    }

    @Test("A quick pass carries the brief and the notes it is asked about")
    func quickPromptCarriesBriefAndNotes() {
        let note = CritiquePreviousNote(
            key: "n1", category: "Logic and credibility",
            location: "paragraph 2", quote: "90%", why: "No source."
        )
        let prompt = CritiqueRequest.prompt(
            forDocument: draft, skill: skill, previous: [note],
            brief: CritiqueBrief("Beginners."), depth: .quick
        )
        #expect(prompt.contains("Beginners."))
        #expect(prompt.contains(CritiqueRequest.briefFence))
        #expect(prompt.contains(CritiqueRequest.notesFence))
        #expect(prompt.contains(#""previous""#))
    }

    @Test("A full critique is asked exactly what it always was")
    func fullPromptIsUnchanged() {
        let byDefault = CritiqueRequest.prompt(forDocument: draft, skill: skill)
        #expect(CritiqueRequest.prompt(forDocument: draft, skill: skill, depth: .full) == byDefault)
        #expect(!byDefault.contains("QUICK PASS"))
        #expect(byDefault.contains("Include every high and medium finding"))
        #expect(byDefault.contains(#""whatWorks" is not flattery"#))
    }

    // MARK: - What is kept

    private let report = CritiqueReport(jobRead: "Developers.", overall: "Fine.", findings: [])

    @Test("A quick pass is remembered as one")
    func revisionRoundTrips() throws {
        let quick = CritiqueRevision(report: report, documentText: draft, depth: .quick)
        #expect(quick.isQuick)
        #expect(quick.depth == .quick)
        let back = try JSONDecoder().decode(
            CritiqueRevision.self, from: JSONEncoder().encode(quick)
        )
        #expect(back == quick)
        #expect(back.isQuick)
    }

    @Test("A full critique writes no depth, so older builds read it unchanged")
    func fullOmitsTheField() throws {
        let full = CritiqueRevision(report: report, documentText: draft, depth: .full)
        #expect(full.depth == nil)
        #expect(!full.isQuick)
        #expect(full == CritiqueRevision(
            id: full.id, date: full.date, report: report, documentText: draft
        ))
        let json = String(decoding: try JSONEncoder().encode(full), as: UTF8.self)
        #expect(!json.contains("depth"))
    }

    /// A revision as a file holds it, with `depth` set to whatever is given
    /// — or left out, as every history written before it existed has it.
    private func stored(depth: String?) throws -> Data {
        let full = try JSONEncoder().encode(CritiqueRevision(report: report, documentText: draft))
        var object = try #require(
            try JSONSerialization.jsonObject(with: full) as? [String: Any]
        )
        #expect(object["depth"] == nil)
        if let depth { object["depth"] = depth }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("A history written before depths existed loads as full critiques")
    func olderHistoryLoads() throws {
        let back = try JSONDecoder().decode(CritiqueRevision.self, from: stored(depth: nil))
        #expect(back.depth == nil)
        #expect(!back.isQuick)
        #expect(back.documentText == draft)
    }

    @Test("A depth this build has never heard of is read as a full critique")
    func unknownDepthIsFull() throws {
        // Rather than failing the whole history over one word.
        let back = try JSONDecoder().decode(
            CritiqueRevision.self, from: stored(depth: "forensic")
        )
        #expect(!back.isQuick)
        #expect(back.documentText == draft)
        #expect(try JSONDecoder().decode(
            CritiqueRevision.self, from: stored(depth: "quick")
        ).isQuick)
    }

    @Test("A quick pass never replaces a full critique of the same text")
    func historyKeepsTheFullerRead() {
        var history = CritiqueHistory()
        history.add(CritiqueRevision(report: report, documentText: draft))
        history.add(CritiqueRevision(report: report, documentText: draft, depth: .quick))
        #expect(history.revisions.map(\.isQuick) == [true, false])

        // Another quick pass of the same text is the same opinion again.
        history.add(CritiqueRevision(report: report, documentText: draft, depth: .quick))
        #expect(history.revisions.map(\.isQuick) == [true, false])

        // A full one says everything the quick one could.
        history.add(CritiqueRevision(report: report, documentText: draft))
        #expect(history.revisions.map(\.isQuick) == [false, false])
    }

    @Test("The history menu names a quick pass rather than scoring it")
    func label() {
        let finding = CritiqueFinding(
            severity: .high, category: "Grammar and mechanics",
            location: "paragraph 1", quote: "cacheing", why: "Misspelled."
        )
        let marked = CritiqueReport(jobRead: "", overall: "", findings: [finding])
        #expect(CritiqueRevisionLabel.measure(
            CritiqueRevision(report: marked, documentText: draft, depth: .quick)
        ) == "Quick pass")
        let full = CritiqueRevision(report: marked, documentText: draft)
        #expect(CritiqueRevisionLabel.measure(full) == "\(full.score)/100")
    }
}
