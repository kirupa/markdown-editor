import Foundation
import MarkdownEditorContract
import Testing
@testable import MarkdownEditorCore

/// The promise the incremental renderer makes: rendering a document a block at
/// a time gives back exactly what rendering the whole thing would have given.
///
/// "Exactly" is meant literally — the same rendered text, the same spans in the
/// same order, and the same mapping at every single offset in both directions.
/// Anything less is not a performance improvement, it is a way of writing the
/// wrong bytes into somebody's file, because every edit made in the rendered
/// view is mapped back through that table before it reaches the source.
///
/// The second half of the suite counts blocks. A keystroke that re-parses the
/// document is the fault this work exists to remove, and counting the work is
/// the only way to check for it that does not turn into a flaky clock.
@Suite("Incremental rendering")
struct MarkdownIncrementalRenderTests {
    // MARK: - Helpers

    /// Checks a renderer against the one-shot renderer, offset by offset.
    ///
    /// Reports the first disagreement rather than every one of them: a
    /// mapping that has drifted disagrees at thousands of offsets, and
    /// thousands of recorded failures take far longer to print than to find.
    private static func expectMatchesFullRender(
        _ renderer: MarkdownIncrementalRenderer,
        source: String,
        label: String
    ) {
        let expected = MarkdownRenderer.render(source)
        guard renderer.renderedText() == expected.text else {
            Issue.record("\(label): rendered text differs")
            return
        }
        guard renderer.allSpans() == expected.spans else {
            Issue.record("\(label): spans differ")
            return
        }
        if let complaint = firstMappingDifference(
            renderer,
            expected: expected,
            sourceLength: (source as NSString).length
        ) {
            Issue.record("\(label): \(complaint)")
        }
    }

    private static func firstMappingDifference(
        _ renderer: MarkdownIncrementalRenderer,
        expected: MarkdownRenderModel,
        sourceLength: Int
    ) -> String? {
        let renderedLength = (expected.text as NSString).length
        // The two offset tables and the span list are everything the public
        // mappings are computed from, so comparing them at every offset is a
        // stronger check than sampling the mappings themselves — and it is
        // linear rather than quadratic, which matters when it runs for every
        // caret position in the corpus.
        for offset in 0...renderedLength {
            let mineUpper = renderer.upperSourceOffsetForTesting(at: offset)
            let theirsUpper = expected.upperSourceOffset(at: offset)
            if mineUpper != theirsUpper {
                return """
                    rendered \(offset) starts at source \(mineUpper), \
                    not \(theirsUpper)
                    """
            }
            let mineLower = renderer.lowerSourceOffsetForTesting(at: offset)
            let theirsLower = expected.lowerSourceOffset(at: offset)
            if mineLower != theirsLower {
                return """
                    rendered \(offset) ends at source \(mineLower), \
                    not \(theirsLower)
                    """
            }
        }
        // And a walk over the mappings themselves, so the two bodies that read
        // those tables cannot drift apart later without something failing.
        for offset in stride(from: 0, through: renderedLength, by: 3) {
            for length in [0, 2] where offset + length <= renderedLength {
                let range = NSRange(location: offset, length: length)
                let mine = renderer.sourceRange(for: range)
                let theirs = expected.sourceRange(for: range)
                if mine != theirs {
                    return "rendered \(range) maps to \(mine), not \(theirs)"
                }
                let mineMarkup = renderer.sourceRange(
                    for: range,
                    includingMarkup: true
                )
                let theirsMarkup = expected.sourceRange(
                    for: range,
                    includingMarkup: true
                )
                if mineMarkup != theirsMarkup {
                    return """
                        rendered \(range) with markup maps to \(mineMarkup), \
                        not \(theirsMarkup)
                        """
                }
            }
        }
        for offset in stride(from: 0, through: sourceLength, by: 3) {
            for length in [0, 2] where offset + length <= sourceLength {
                let range = NSRange(location: offset, length: length)
                let mine = renderer.renderedRange(for: range)
                let theirs = expected.renderedRange(for: range)
                if mine != theirs {
                    return "source \(range) maps to \(mine), not \(theirs)"
                }
            }
        }
        return nil
    }

    /// Applies an edit to a string the way the renderer will.
    private static func applying(
        _ replacement: String,
        to source: String,
        in range: NSRange
    ) -> String {
        (source as NSString).replacingCharacters(in: range, with: replacement)
    }

    // MARK: - Equivalence

    @Test("A freshly built renderer matches the one-shot renderer")
    func buildsTheSameAsAFullRender() {
        for document in ContractCorpus.documents {
            let renderer = MarkdownIncrementalRenderer(source: document.text)
            Self.expectMatchesFullRender(
                renderer,
                source: document.text,
                label: document.id
            )
        }
    }

    @Test("Typing a character anywhere in the corpus stays equivalent")
    func typingStaysEquivalent() {
        for document in ContractCorpus.documents {
            let source = document.text as NSString
            for offset in 0...source.length {
                for typed in ["x", "\n", "#", "`", "*", "-", " "] {
                    let renderer = MarkdownIncrementalRenderer(
                        source: document.text
                    )
                    let range = NSRange(location: offset, length: 0)
                    renderer.replace(sourceRange: range, with: typed)
                    let updated = Self.applying(
                        typed,
                        to: document.text,
                        in: range
                    )
                    Self.expectMatchesFullRender(
                        renderer,
                        source: updated,
                        label: "\(document.id) typed \(typed) at \(offset)"
                    )
                }
            }
        }
    }

    @Test("Deleting anywhere in the corpus stays equivalent")
    func deletingStaysEquivalent() {
        for document in ContractCorpus.documents {
            let source = document.text as NSString
            for offset in 0..<max(1, source.length) where source.length > 0 {
                for length in 1...min(4, source.length - offset) {
                    let range = NSRange(location: offset, length: length)
                    guard
                        range.location
                            == source.rangeOfComposedCharacterSequence(
                                at: range.location
                            ).location
                    else { continue }
                    let renderer = MarkdownIncrementalRenderer(
                        source: document.text
                    )
                    renderer.replace(sourceRange: range, with: "")
                    let updated = Self.applying(
                        "",
                        to: document.text,
                        in: range
                    )
                    Self.expectMatchesFullRender(
                        renderer,
                        source: updated,
                        label: "\(document.id) deleted \(range)"
                    )
                }
            }
        }
    }

    @Test("A long stream of edits never drifts from a full render")
    func aStreamOfEditsNeverDrifts() {
        var generator = SplitMix64(seed: 0x4B4F4E564F)
        let alphabet = Array(
            "ab \n#`*->[]()!_~\\1.😀"
        )
        for document in ContractCorpus.documents {
            var source = document.text
            let renderer = MarkdownIncrementalRenderer(source: source)
            for step in 0..<40 {
                let length = (source as NSString).length
                let location = length == 0
                    ? 0
                    : Int(generator.next() % UInt64(length + 1))
                let removable = max(0, length - location)
                let removed = removable == 0
                    ? 0
                    : Int(generator.next() % UInt64(min(6, removable) + 1))
                var range = NSRange(location: location, length: removed)
                range = (source as NSString)
                    .rangeOfComposedCharacterSequences(for: range)
                var insertion = ""
                let insertionLength = Int(generator.next() % 4)
                for _ in 0..<insertionLength {
                    insertion.append(
                        alphabet[Int(generator.next() % UInt64(alphabet.count))]
                    )
                }
                renderer.replace(sourceRange: range, with: insertion)
                source = Self.applying(insertion, to: source, in: range)
                Self.expectMatchesFullRender(
                    renderer,
                    source: source,
                    label: "\(document.id) step \(step)"
                )
            }
        }
    }

    // MARK: - Edits that change the structure around them

    @Test("Opening and closing a fence re-renders what it swallows")
    func fencesWidenTheDirtyRange() {
        let source = """
        Before.

        one
        two

        After.

        """
        let renderer = MarkdownIncrementalRenderer(source: source)
        let insertion = "```\n"
        let range = NSRange(location: (("Before.\n\n") as NSString).length, length: 0)
        renderer.replace(sourceRange: range, with: insertion)
        let opened = Self.applying(insertion, to: source, in: range)
        Self.expectMatchesFullRender(renderer, source: opened, label: "fence opened")

        // Closing it again must put every swallowed line back as it was.
        let closingLocation = (opened as NSString).length
        renderer.replace(
            sourceRange: NSRange(location: closingLocation, length: 0),
            with: "```\n"
        )
        let closed = Self.applying(
            "```\n",
            to: opened,
            in: NSRange(location: closingLocation, length: 0)
        )
        Self.expectMatchesFullRender(renderer, source: closed, label: "fence closed")
    }

    @Test("Typing the third backtick of a fence is equivalent at every step")
    func typingAFenceOneCharacterAtATime() {
        var source = "Alpha\n\nbeta\n\ngamma\n"
        let renderer = MarkdownIncrementalRenderer(source: source)
        let insertAt = ("Alpha\n\n" as NSString).length
        for step in 0..<3 {
            let range = NSRange(location: insertAt + step, length: 0)
            renderer.replace(sourceRange: range, with: "`")
            source = Self.applying("`", to: source, in: range)
            Self.expectMatchesFullRender(
                renderer,
                source: source,
                label: "backtick \(step + 1)"
            )
        }
    }

    @Test("Adding and removing a heading marker stays equivalent")
    func headingMarkersStayEquivalent() {
        var source = "Title\n\nBody text here.\n"
        let renderer = MarkdownIncrementalRenderer(source: source)
        renderer.replace(sourceRange: NSRange(location: 0, length: 0), with: "# ")
        source = Self.applying("# ", to: source, in: NSRange(location: 0, length: 0))
        Self.expectMatchesFullRender(renderer, source: source, label: "heading added")

        renderer.replace(sourceRange: NSRange(location: 0, length: 2), with: "")
        source = Self.applying("", to: source, in: NSRange(location: 0, length: 2))
        Self.expectMatchesFullRender(renderer, source: source, label: "heading removed")
    }

    @Test("Deleting across a block boundary stays equivalent")
    func deletingAcrossBlocksStaysEquivalent() {
        let source = "- one\n- two\n- three\n\n> quoted\n"
        let renderer = MarkdownIncrementalRenderer(source: source)
        let range = NSRange(location: 4, length: 9)
        renderer.replace(sourceRange: range, with: "")
        let updated = Self.applying("", to: source, in: range)
        Self.expectMatchesFullRender(renderer, source: updated, label: "across blocks")
    }

    @Test("Pasting a large block stays equivalent")
    func pastingALargeBlockStaysEquivalent() {
        let source = "Start\n\nEnd\n"
        let renderer = MarkdownIncrementalRenderer(source: source)
        var pasted = ""
        for index in 0..<200 {
            pasted += "## Section \(index)\n\n- item **\(index)**\n\n"
        }
        let range = NSRange(location: 7, length: 0)
        renderer.replace(sourceRange: range, with: pasted)
        let updated = Self.applying(pasted, to: source, in: range)
        #expect(renderer.renderedText() == MarkdownRenderer.render(updated).text)
        #expect(renderer.allSpans() == MarkdownRenderer.render(updated).spans)
    }

    @Test("A document that is one very long line stays equivalent")
    func oneVeryLongLineStaysEquivalent() {
        let source = String(repeating: "word ", count: 20_000)
        let renderer = MarkdownIncrementalRenderer(source: source)
        let range = NSRange(location: 50_000, length: 0)
        renderer.replace(sourceRange: range, with: "**bold**")
        let updated = Self.applying("**bold**", to: source, in: range)
        #expect(renderer.renderedText() == MarkdownRenderer.render(updated).text)
        #expect(renderer.allSpans() == MarkdownRenderer.render(updated).spans)
    }

    @Test("A whole-document replacement is still correct")
    func wholeDocumentReplacement() {
        let renderer = MarkdownIncrementalRenderer(source: "# One\n\nTwo\n")
        renderer.update(source: "> Completely different\n\n- list\n")
        Self.expectMatchesFullRender(
            renderer,
            source: "> Completely different\n\n- list\n",
            label: "replaced"
        )
    }

    @Test("Emptying and refilling a document is still correct")
    func emptyingAndRefilling() {
        let renderer = MarkdownIncrementalRenderer(source: "# One\n\nTwo\n")
        renderer.replace(
            sourceRange: NSRange(location: 0, length: ("# One\n\nTwo\n" as NSString).length),
            with: ""
        )
        Self.expectMatchesFullRender(renderer, source: "", label: "emptied")
        renderer.replace(sourceRange: NSRange(location: 0, length: 0), with: "# Back\n")
        Self.expectMatchesFullRender(renderer, source: "# Back\n", label: "refilled")
    }

    // MARK: - Questions asked at the edges

    /// The caret at the very end of an unclosed fence is still in the fence.
    ///
    /// It decides whether Return inserts a plain newline or runs the list
    /// continuation, so getting it wrong writes `- ` or `2. ` into somebody's
    /// code.
    @Test("The end of an unclosed fence still counts as inside it")
    func endOfAnUnclosedFenceIsInsideIt() {
        for source in ["```\n- item", "```swift\nlet x = 1\n", "~~~\n1. one"] {
            let renderer = MarkdownIncrementalRenderer(source: source)
            let end = (source as NSString).length
            #expect(
                renderer.isInsideCodeBlock(sourceOffset: end),
                "\(source.debugDescription): the end was reported as outside"
            )
        }
    }

    @Test("A closed fence ends where it says it does")
    func closedFenceBoundaries() {
        let source = "```\ncode\n```\nafter\n"
        let renderer = MarkdownIncrementalRenderer(source: source)
        #expect(renderer.isInsideCodeBlock(sourceOffset: 5))
        #expect(
            !renderer.isInsideCodeBlock(
                sourceOffset: (source as NSString).length
            ),
            "the paragraph after the fence is not in it"
        )
    }

    /// The caret's own block style lives in a span with no characters in it,
    /// sitting at the very end of the rendered text. A query that cannot see
    /// it leaves a new quote or list line drawn flush against the margin.
    @Test("A zero-length span at the end of the document can be found")
    func zeroLengthSpanAtTheEndIsFound() {
        for source in ["a\n> ", "a\n# ", "> quote\n> ", "#### "] {
            let renderer = MarkdownIncrementalRenderer(source: source)
            let end = renderer.renderedLength
            let found = renderer.spans(
                inRenderedRange: NSRange(location: end, length: 0)
            )
            let expected = MarkdownRenderer.render(source).spans.filter {
                $0.renderedRange.length == 0 && $0.renderedRange.location == end
            }
            #expect(
                !expected.isEmpty,
                "\(source.debugDescription): the corpus assumption is wrong"
            )
            for span in expected {
                #expect(
                    found.contains(span),
                    "\(source.debugDescription): \(span.style) was not found"
                )
            }
        }
    }

    /// The block scanner and the parser have to agree about what opens a
    /// fence, or a block renders one way alone and another way in context.
    @Test("A fence indented with unusual whitespace still opens a block")
    func unusualWhitespaceBeforeAFence() {
        for blank in ["\u{00A0}", "\u{2003}", "\u{3000}", " \u{00A0}"] {
            let source = "\(blank)```\nA **bold** line\n```\nafter\n"
            let renderer = MarkdownIncrementalRenderer(source: source)
            Self.expectMatchesFullRender(
                renderer,
                source: source,
                label: "fence indented with \(blank.debugDescription)"
            )
        }
    }

    // MARK: - Locality

    /// A document long enough that re-rendering it would be obvious, built out
    /// of every construct the renderer knows so the count is not measuring an
    /// easy case.
    private static func longDocument(paragraphs: Int) -> String {
        var text = ""
        for index in 0..<paragraphs {
            text += "## Heading \(index)\n\n"
            text += "Some **bold** and *italic* and `code` with a "
            text += "[link](https://example.com/\(index)).\n\n"
            text += "- [ ] task \(index)\n- bullet \(index)\n\n"
            text += "> quoted line \(index)\n\n"
            text += "```swift\nlet value\(index) = \(index)\n```\n\n"
        }
        return text
    }

    @Test("A keystroke in a long document re-renders a handful of blocks")
    func aKeystrokeIsLocal() {
        let source = Self.longDocument(paragraphs: 700)
        let renderer = MarkdownIncrementalRenderer(source: source)
        let length = (source as NSString).length
        #expect(length > 100_000, "the document should be long enough to matter")

        // Typing in the middle, at the end, and near the start: none of them
        // may cost more than the block they landed in.
        for location in [length / 2, length - 2, 40] {
            let update = renderer.replace(
                sourceRange: NSRange(location: location, length: 0),
                with: "x"
            )
            #expect(
                update.reparsedBlockCount <= 2,
                """
                typing at \(location) re-parsed \(update.reparsedBlockCount) \
                blocks
                """
            )
            #expect(
                update.renderedRange.length < 400,
                """
                typing at \(location) re-styled \
                \(update.renderedRange.length) characters
                """
            )
        }
    }

    @Test("The work a keystroke does is the same in a long and a short document")
    func localityDoesNotScaleWithLength() {
        func blocksTouchedTypingInTheMiddle(paragraphs: Int) -> Int {
            let source = Self.longDocument(paragraphs: paragraphs)
            let renderer = MarkdownIncrementalRenderer(source: source)
            let update = renderer.replace(
                sourceRange: NSRange(
                    location: (source as NSString).length / 2,
                    length: 0
                ),
                with: "z"
            )
            return update.reparsedBlockCount
        }

        let small = blocksTouchedTypingInTheMiddle(paragraphs: 10)
        let large = blocksTouchedTypingInTheMiddle(paragraphs: 1_000)
        #expect(small == large, "\(small) blocks for a short document, \(large) for a long one")
    }

    @Test("Deleting a selection spanning two blocks re-renders those blocks")
    func deletingAcrossTwoBlocksIsLocal() {
        let source = Self.longDocument(paragraphs: 200)
        let renderer = MarkdownIncrementalRenderer(source: source)
        let middle = (source as NSString).length / 2
        let update = renderer.replace(
            sourceRange: NSRange(location: middle, length: 30),
            with: ""
        )
        #expect(update.reparsedBlockCount <= 4, "\(update.reparsedBlockCount) blocks")
    }

    @Test("Blocks an edit did not touch keep the very model they had")
    func untouchedBlocksAreNotRebuilt() {
        let source = Self.longDocument(paragraphs: 50)
        let renderer = MarkdownIncrementalRenderer(source: source)
        let before = renderer.blockModelIdentitiesForTesting()
        let middle = (source as NSString).length / 2
        renderer.replace(sourceRange: NSRange(location: middle, length: 0), with: "q")
        let after = renderer.blockModelIdentitiesForTesting()

        #expect(before.count == after.count, "the block count should not change")
        let changed = zip(before, after).filter { $0 != $1 }.count
        #expect(
            changed <= 2,
            "\(changed) of \(before.count) blocks were rebuilt by one keystroke"
        )
    }
}

/// A small deterministic generator, so a failing fuzz case is reproducible
/// rather than a story about a build that went red once.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
