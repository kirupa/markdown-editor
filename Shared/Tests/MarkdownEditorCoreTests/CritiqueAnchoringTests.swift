import Foundation
import Testing

@testable import MarkdownEditorCore

/// Putting each finding's highlight on the passage it is about.
///
/// The failure that matters here is a silent one: a highlight that lands on
/// the wrong sentence still looks like a working feature, and the author
/// simply reads a criticism that does not match the words under it.
@Suite("Critique anchoring")
struct CritiqueAnchoringTests {
    private func finding(
        quote: String,
        location: String = "",
        severity: CritiqueSeverity = .medium
    ) -> CritiqueFinding {
        CritiqueFinding(
            severity: severity,
            category: "Clarity and precision",
            location: location,
            quote: quote,
            why: "because"
        )
    }

    private let draft = """
        # Understanding Caching

        Caching is important because the cache stores data for later reads.

        The way caching works is that the cache stores data. It is faster.

        Studies show that caching improves performance by 90%.
        """

    @Test("A verbatim quote lands exactly on its words")
    func exactQuoteAnchors() throws {
        let range = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "improves performance by 90%"),
                in: draft
            )
        )
        #expect(
            (draft as NSString).substring(with: range)
                == "improves performance by 90%"
        )
    }

    @Test("A quote the model retyped still lands on the original words")
    func retypedQuotesStillAnchor() throws {
        // A model reproduces a passage as often as it copies one: straight
        // quotes for curly, one space for a line break, collapsed runs. The
        // passage is still in the draft; the bytes are not.
        let source = "He said \u{201C}it\u{2019}s fine\u{201D} and\nthen  left."
        let range = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "\"it's fine\" and then left."),
                in: source
            )
        )
        let matched = (source as NSString).substring(with: range)
        #expect(matched == "\u{201C}it\u{2019}s fine\u{201D} and\nthen  left.")
    }

    @Test("The highlight covers real characters, not folded ones")
    func relaxedMatchesReportOriginalOffsets() throws {
        // Folding is only a way to compare. If the range came from the folded
        // string the highlight would drift by however much whitespace was
        // collapsed before it — worse the further down the document you go.
        let source = "Alpha.\n\n\n\nBeta   gamma delta."
        let range = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "Beta gamma"),
                in: source
            )
        )
        #expect((source as NSString).substring(with: range) == "Beta   gamma")
    }

    @Test("A quote that is not in the draft anchors nowhere")
    func aParaphraseIsNotAnchored() {
        // Better to say so than to highlight the nearest thing that looks a
        // bit like it, which reads as the app misunderstanding the draft.
        #expect(
            CritiqueAnchoring.range(
                for: finding(quote: "a sentence the author never wrote"),
                in: draft
            ) == nil
        )
    }

    @Test("An empty quote anchors nowhere rather than to the start")
    func anEmptyQuoteIsNotAnchored() {
        #expect(CritiqueAnchoring.range(for: finding(quote: "   "), in: draft) == nil)
    }

    @Test("A repeated quote uses the paragraph the finding names")
    func theLocationDisambiguates() throws {
        // "the cache stores data" is in paragraphs 2 and 3. Highlighting the first
        // every time would put half the findings on the wrong sentence, and
        // nothing on screen would say so.
        let second = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "the cache stores data", location: "paragraph 3"),
                in: draft
            )
        )
        let first = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "the cache stores data", location: "paragraph 2"),
                in: draft
            )
        )
        #expect(first.location < second.location)

        let paragraphs = CritiqueAnchoring.paragraphRanges(in: draft)
        #expect(NSIntersectionRange(paragraphs[2], second).length > 0)
    }

    @Test("A location with no paragraph number falls back to the first match")
    func noNumberMeansTheFirstOccurrence() throws {
        let range = try #require(
            CritiqueAnchoring.range(
                for: finding(quote: "the cache stores data", location: "Opening"),
                in: draft
            )
        )
        let first = (draft as NSString).range(of: "the cache stores data")
        #expect(range == first)
    }

    @Test("Two findings quoting the same words get an occurrence each")
    func identicalQuotesDoNotStack() throws {
        let anchors = CritiqueAnchoring.anchor(
            [finding(quote: "the cache stores data"), finding(quote: "the cache stores data")],
            in: draft
        )
        let ranges = anchors.compactMap(\.range)
        #expect(ranges.count == 2)
        #expect(ranges[0] != ranges[1], "each card needs its own highlight")
    }

    @Test("A paragraph number counts blocks, not lines")
    func paragraphsAreBlocksNotLines() {
        // A critique numbers paragraphs the way a reader does. Counting
        // newlines instead would make every number after the first wrapped
        // paragraph point somewhere else.
        let wrapped = "One.\n\nTwo line one\nTwo line two\n\nThree."
        let paragraphs = CritiqueAnchoring.paragraphRanges(in: wrapped)
        #expect(paragraphs.count == 3)
        #expect(
            (wrapped as NSString).substring(with: paragraphs[1])
                .contains("Two line two")
        )
    }

    @Test("A paragraph number is read out of the skill's own phrasing")
    func locationsAreParsed() {
        #expect(CritiqueAnchoring.paragraphNumber(in: "paragraph 4") == 4)
        #expect(
            CritiqueAnchoring.paragraphNumber(in: "\"Failure modes,\" paragraph 12") == 12
        )
        #expect(CritiqueAnchoring.paragraphNumber(in: "Opening") == nil)
        #expect(CritiqueAnchoring.paragraphNumber(in: "whole draft") == nil)
    }

    @Test("Anchoring keeps the findings in the order they arrived")
    func orderIsPreserved() {
        let findings = [
            finding(quote: "Studies show"),
            finding(quote: "nowhere at all"),
            finding(quote: "Caching is important"),
        ]
        let anchors = CritiqueAnchoring.anchor(findings, in: draft)
        #expect(anchors.count == 3)
        #expect(anchors.map(\.findingID) == findings.map(\.id))
        #expect(anchors[1].isAnchored == false)
    }
}
