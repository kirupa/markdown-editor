import Foundation
import Testing

@testable import MarkdownEditorCore

@Suite("Critiquing only what changed")
struct CritiqueScopeTests {
    private let draft = """
        # Caching

        Caching is a very important technique that every developer \
        should know about.

        A page that recomputes the same query for every visitor \
        spends most of its life doing work it already did.

        The tradeoff is staleness.
        """

    // MARK: - Finding the change

    @Test("An unchanged draft has nothing to re-read")
    func unchanged() {
        #expect(CritiqueChangeScope.changedParagraphs(from: draft, to: draft) == nil)
    }

    @Test("A word typed into a paragraph widens to the whole paragraph")
    func widensToParagraph() {
        let edited = draft.replacingOccurrences(
            of: "The tradeoff is staleness.",
            with: "The tradeoff is staleness and cost."
        )
        let changed = CritiqueChangeScope.changedParagraphs(from: draft, to: edited)
        let passage = try! #require(changed.map {
            CritiqueChangeScope.passage($0, in: edited)
        })
        // Not " and cost", which is all the raw diff would give: a critique of
        // two words cannot see the sentence they landed in.
        #expect(passage == "The tradeoff is staleness and cost.")
    }

    @Test("A new paragraph at the end is the passage, and the rest is not")
    func newParagraph() {
        let edited = draft + "\n\nCache invalidation is the hard part.\n"
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: draft, to: edited)
        )
        let passage = CritiqueChangeScope.passage(changed, in: edited)
        #expect(passage.contains("Cache invalidation is the hard part."))
        #expect(!passage.contains("very important technique"))
        #expect(!passage.contains("# Caching"))
    }

    @Test("Appending a paragraph does not swallow the one above it")
    func appendedParagraphStandsAlone() {
        // The draft already ends in a newline, and appending inserts the blank
        // line as well as the words: "\n\nCache invalidation…". That separator
        // belongs to the gap. Without trimming it the search starts inside the
        // previous paragraph's trailing newline, finds one line break before
        // hitting text, and decides the previous paragraph changed too.
        //
        // Found by watching the app: adding a paragraph retired a good note
        // about the sentence above it. Every earlier test edited the middle of
        // a draft, where this asymmetry does not show.
        let ending = draft + "\n"
        let edited = ending + "\nCache invalidation is genuinely the hard part.\n"
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: ending, to: edited)
        )
        let passage = CritiqueChangeScope.passage(changed, in: edited)
        #expect(passage == "Cache invalidation is genuinely the hard part.")
        #expect(!passage.contains("The tradeoff"))
    }

    @Test("Splitting a paragraph re-reads the paragraph that was split")
    func pureSeparatorInsertion() {
        // Pressing Return and nothing else: the inserted text is all
        // separator, so it trims to nothing and the edit point decides.
        let before = "One long paragraph that says two things at once."
        let after = "One long paragraph\n\nthat says two things at once."
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: before, to: after)
        )
        let passage = CritiqueChangeScope.passage(changed, in: after)
        #expect(!passage.isEmpty)
        #expect(after.contains(passage))
    }

    @Test("A paragraph is bounded by blank lines, not by every line break")
    func listsAreOneThing() {
        let list = """
            Intro paragraph.

            - one
            - two
            - three

            Closing paragraph.
            """
        let edited = list.replacingOccurrences(of: "- two", with: "- two and a half")
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: list, to: edited)
        )
        let passage = CritiqueChangeScope.passage(changed, in: edited)
        // The whole list, because a list is one thing to judge — handing the
        // model "- two and a half" alone asks what is wrong with a fragment.
        #expect(passage == "- one\n- two and a half\n- three")
    }

    @Test("Deleting text still reports the paragraph it was cut from")
    func deletion() {
        let edited = draft.replacingOccurrences(
            of: " that every developer should know about", with: ""
        )
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: draft, to: edited)
        )
        let passage = CritiqueChangeScope.passage(changed, in: edited)
        #expect(passage == "Caching is a very important technique.")
    }

    @Test("Edits in two places collapse into one span covering both")
    func twoEdits() {
        var edited = draft.replacingOccurrences(of: "# Caching", with: "# On Caching")
        edited = edited.replacingOccurrences(
            of: "The tradeoff is staleness.",
            with: "The tradeoff is staleness and cost."
        )
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: draft, to: edited)
        )
        let passage = CritiqueChangeScope.passage(changed, in: edited)
        // Over-reading, on purpose. A prefix/suffix diff cannot see two islands,
        // and reading too much costs tokens while reading too little silently
        // keeps notes about text that is gone.
        #expect(passage.contains("# On Caching"))
        #expect(passage.contains("and cost."))
    }

    // MARK: - Whether narrowing is worth it

    @Test("A change covering most of the draft is not worth narrowing")
    func rewriteIsNotPartial() {
        let rewritten = "Everything about this draft is different now, entirely."
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: draft, to: rewritten)
        )
        #expect(!CritiqueChangeScope.isWorthScoping(changed, in: rewritten))
    }

    @Test("A new paragraph in a long draft is worth narrowing")
    func additionIsPartial() {
        let edited = draft + "\n\nCache invalidation is genuinely the hard part.\n"
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: draft, to: edited)
        )
        #expect(CritiqueChangeScope.isWorthScoping(changed, in: edited))
    }

    @Test("A passage too short to quote is not worth narrowing")
    func tinyChange() {
        let short = "Hi.\n\nBye."
        let edited = "Hi.\n\nBye!"
        let changed = try! #require(
            CritiqueChangeScope.changedParagraphs(from: short, to: edited)
        )
        #expect(!CritiqueChangeScope.isWorthScoping(changed, in: edited))
    }

    // MARK: - Which notes survive

    @Test("A note outside the changed passage is kept")
    func keepsNotesElsewhere() {
        let changed = NSRange(location: 100, length: 50)
        let survives = CritiqueChangeScope.surviving(
            [NSRange(location: 10, length: 20)], changed: changed
        )
        #expect(survives == [true])
    }

    @Test("A note inside the changed passage is superseded")
    func dropsNotesInside() {
        let changed = NSRange(location: 100, length: 50)
        let survives = CritiqueChangeScope.surviving(
            [NSRange(location: 110, length: 10)], changed: changed
        )
        #expect(survives == [false])
    }

    @Test("A note overlapping the edge of the change is superseded")
    func dropsOverlapping() {
        let changed = NSRange(location: 100, length: 50)
        #expect(
            CritiqueChangeScope.surviving(
                [NSRange(location: 90, length: 20)], changed: changed
            ) == [false]
        )
        #expect(
            CritiqueChangeScope.surviving(
                [NSRange(location: 140, length: 20)], changed: changed
            ) == [false]
        )
    }

    @Test("A note that ends exactly where the change begins is kept")
    func touchingEdgesAreNotOverlaps() {
        let changed = NSRange(location: 100, length: 50)
        // [80, 100) and [100, 150) share no character.
        #expect(
            CritiqueChangeScope.surviving(
                [NSRange(location: 80, length: 20)], changed: changed
            ) == [true]
        )
        #expect(
            CritiqueChangeScope.surviving(
                [NSRange(location: 150, length: 20)], changed: changed
            ) == [true]
        )
    }

    @Test("A note whose quote can no longer be found is kept")
    func keepsUnanchored() {
        // Its position is exactly what is unknown, so it may be about text this
        // run never looked at. The rail already shows it as not pointing at
        // anything; dropping it would decide for the author on a guess.
        #expect(
            CritiqueChangeScope.surviving([nil], changed: NSRange(location: 0, length: 10))
                == [true]
        )
    }

    @Test("An emptied note sitting at the edit point is superseded")
    func zeroLengthAtTheEdit() {
        // Zero-length ranges intersect nothing by NSIntersectionRange's
        // reckoning, which would keep a note about text that was deleted to
        // nothing by this very edit.
        #expect(
            CritiqueChangeScope.surviving(
                [NSRange(location: 100, length: 0)],
                changed: NSRange(location: 100, length: 50)
            ) == [false]
        )
    }

    // MARK: - The request

    @Test("A narrowed request still sends the whole draft")
    func focusKeepsContext() {
        let prompt = CritiqueRequest.prompt(
            forDocument: draft, focus: "The tradeoff is staleness."
        )
        // Everything, because a paragraph cannot be judged alone: whether it
        // repeats what came before is the whole question.
        #expect(prompt.contains("very important technique"))
        #expect(prompt.contains("Cache") || prompt.contains("# Caching"))
        #expect(prompt.contains("CHANGED PASSAGE"))
        #expect(prompt.contains("do not write findings about text outside"))
    }

    @Test("A narrowed request still asks for a whole-draft summary")
    func focusKeepsSummary() {
        let prompt = CritiqueRequest.prompt(forDocument: draft, focus: "Something.")
        #expect(prompt.contains("describe the WHOLE draft"))
    }

    @Test("An unnarrowed request says nothing about a changed passage")
    func wholeHasNoFocus() {
        let prompt = CritiqueRequest.prompt(forDocument: draft)
        #expect(!prompt.contains("CHANGED PASSAGE"))
        #expect(!prompt.contains("has been edited since"))
    }

    @Test("The passage is quoted after the draft, never marked inside it")
    func draftIsNotAnnotated() {
        let focus = "The tradeoff is staleness."
        let prompt = CritiqueRequest.prompt(forDocument: draft, focus: focus)
        // Markers inside the draft would come back inside the model's quotes,
        // and quotes are found again by exact string search — so an annotated
        // draft breaks every highlight for the passage it meant to help.
        let fenced = prompt.range(of: "<<<DRAFT")!.upperBound
            ..< prompt.range(of: "DRAFT>>>")!.lowerBound
        #expect(!prompt[fenced].contains("CHANGED"))
        #expect(prompt[fenced].contains(focus))
    }

    // MARK: - Merging

    @Test("A merged report carries the kept notes and the new ones")
    func mergedReport() {
        let old = CritiqueFinding(
            severity: .medium, category: "Clarity and precision",
            location: "paragraph 2", quote: "spends most of its life",
            why: "vague", fix: "", direction: ""
        )
        let new = CritiqueFinding(
            severity: .high, category: "Logic and credibility",
            location: "paragraph 4", quote: "The tradeoff is staleness",
            why: "unsupported", fix: "", direction: ""
        )
        let report = CritiqueReport(
            jobRead: "a reader", overall: "fine", findings: [new]
        )
        let merged = report.replacingFindings(with: [old, new])
        #expect(merged.findings.count == 2)
        // The summary is this run's: it was asked about the whole draft even
        // though it only criticised part of it.
        #expect(merged.jobRead == "a reader")
        #expect(merged.overall == "fine")
    }
}
