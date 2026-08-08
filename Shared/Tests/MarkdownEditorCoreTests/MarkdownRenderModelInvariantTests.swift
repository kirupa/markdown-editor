import Foundation
import MarkdownEditorContract
import Testing
@testable import MarkdownEditorCore

/// Structural properties the render model must satisfy for *any* input.
///
/// The rendered view is editable, and every edit made there is mapped back
/// into the Markdown source through the span table. A range that is off by
/// one, out of bounds, or lands in the middle of a character therefore does
/// not merely look wrong — it writes the wrong bytes into the document. These
/// checks exist because that failure is silent and permanent.
///
/// The example tests next door say what specific Markdown should look like.
/// These say what must be true of *everything*, including the half-finished
/// markup that exists for as long as someone is still typing it.
@Suite("Markdown render model invariants")
struct MarkdownRenderModelInvariantTests {
    // MARK: - Helpers

    /// Whether a range lies inside a string and respects character
    /// boundaries.
    ///
    /// UTF-16 offsets can address half of an astral character such as an
    /// emoji. Slicing there throws, so a range that does it would crash the
    /// editor on a document that is perfectly valid.
    private static func isWellFormed(
        _ range: NSRange,
        in text: NSString
    ) -> Bool {
        guard range.location >= 0, range.length >= 0 else { return false }
        guard range.location + range.length <= text.length else { return false }
        if range.location > 0, range.location < text.length {
            // A low surrogate cannot begin a range.
            let unit = text.character(at: range.location)
            if unit >= 0xDC00, unit <= 0xDFFF { return false }
        }
        let end = range.location + range.length
        if end > 0, end < text.length {
            let unit = text.character(at: end)
            if unit >= 0xDC00, unit <= 0xDFFF { return false }
        }
        return true
    }

    /// Every span of a model, checked against both of its strings.
    private static func checkSpans(
        _ model: MarkdownRenderModel,
        source: String,
        label: String
    ) {
        let rendered = model.text as NSString
        let source = source as NSString
        for span in model.spans {
            #expect(
                isWellFormed(span.renderedRange, in: rendered),
                """
                \(label): \(span.style) has rendered range \
                \(span.renderedRange) in text of length \(rendered.length)
                """
            )
            #expect(
                isWellFormed(span.sourceRange, in: source),
                """
                \(label): \(span.style) has source range \
                \(span.sourceRange) in source of length \(source.length)
                """
            )
        }
    }

    // MARK: - Invariants over the shared corpus

    @Test("Every span addresses real text in both strings")
    func spansAreWellFormed() {
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            Self.checkSpans(model, source: document.text, label: document.id)
        }
    }

    /// Rendering the same Markdown twice must give the same answer.
    ///
    /// The rendered pane is rebuilt on a timer as well as on edits. If the
    /// output depended on anything but its input — a dictionary's iteration
    /// order, say — the caret would move on its own while nobody was typing.
    @Test("Rendering is deterministic")
    func renderingIsDeterministic() {
        for document in ContractCorpus.documents {
            let first = MarkdownRenderer.render(document.text)
            let second = MarkdownRenderer.render(document.text)
            #expect(first == second, "\(document.id) rendered differently twice")
        }
    }

    /// Render every prefix of every document, which is what the editor
    /// actually does while someone types one.
    ///
    /// This is where unterminated markup lives: a fence with no closing
    /// fence, `[label](` with no URL yet, a lone `*`. Whole-document tests
    /// never see any of it, because a finished document is balanced. Every
    /// intermediate state must still produce a usable model rather than a
    /// crash or a range that points past the end.
    @Test("Every prefix of every document renders safely")
    func prefixesRenderSafely() {
        var checked = 0
        for document in ContractCorpus.documents {
            for index in document.text.indices {
                let prefix = String(document.text[..<index])
                let model = MarkdownRenderer.render(prefix)
                Self.checkSpans(
                    model,
                    source: prefix,
                    label: "\(document.id) prefix \(prefix.count)"
                )
                checked += 1
            }
        }
        #expect(checked > 1000, "only \(checked) prefixes were rendered")
    }

    /// The same, from the other end.
    ///
    /// A suffix starts in the middle of whatever construct it lands in, so
    /// this covers closing markers with no opener — the mirror image of the
    /// prefix case, and the state a document is in while someone deletes from
    /// the top.
    @Test("Every suffix of every document renders safely")
    func suffixesRenderSafely() {
        for document in ContractCorpus.documents {
            for index in document.text.indices {
                let suffix = String(document.text[index...])
                let model = MarkdownRenderer.render(suffix)
                Self.checkSpans(
                    model,
                    source: suffix,
                    label: "\(document.id) suffix \(suffix.count)"
                )
            }
        }
    }

    // MARK: - The two mappings

    /// Asking where any rendered range came from must give a usable answer.
    ///
    /// This is the mapping used to turn an edit in the rendered pane into an
    /// edit of the source, so an out-of-bounds result here corrupts the file.
    @Test("Every rendered range maps into the source")
    func renderedRangesMapIntoSource() {
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            let rendered = model.text as NSString
            let source = document.text as NSString
            for range in ContractCorpus.selections(in: model.text) {
                guard Self.isWellFormed(range, in: rendered) else { continue }
                let mapped = model.sourceRange(for: range)
                #expect(
                    mapped.location >= 0
                        && mapped.location + mapped.length <= source.length,
                    """
                    \(document.id): rendered \(range) mapped to \(mapped), \
                    outside a source of length \(source.length)
                    """
                )
            }
        }
    }

    /// And the reverse, which is how the caret is mirrored into the rendered
    /// pane when the two are shown side by side.
    @Test("Every source range maps into the rendered text")
    func sourceRangesMapIntoRendered() {
        for document in ContractCorpus.documents {
            let model = MarkdownRenderer.render(document.text)
            let rendered = model.text as NSString
            let source = document.text as NSString
            for range in ContractCorpus.selections(in: document.text) {
                guard Self.isWellFormed(range, in: source) else { continue }
                let mapped = model.renderedRange(for: range)
                #expect(
                    mapped.location >= 0
                        && mapped.location + mapped.length <= rendered.length,
                    """
                    \(document.id): source \(range) mapped to \(mapped), \
                    outside rendered text of length \(rendered.length)
                    """
                )
            }
        }
    }

    /// Out-of-range input must be clamped rather than trapped, and the answer
    /// must itself be usable.
    ///
    /// Both mappings are called with ranges that came from AppKit, which can
    /// hand over a stale selection captured before the last edit shortened
    /// the document. A negative location arrives the same way. Checking only
    /// that the result is non-negative is not enough — a range that starts
    /// past the end of the string it addresses is just as fatal when it is
    /// used to slice text, so both ends are checked here.
    @Test("Both mappings survive impossible ranges")
    func mappingsClampImpossibleRanges() {
        let markdown = "# Title\n\nSome **text** here.\n"
        let model = MarkdownRenderer.render(markdown)
        let renderedLength = (model.text as NSString).length
        let sourceLength = (markdown as NSString).length
        let absurd = [
            NSRange(location: 0, length: 100_000),
            NSRange(location: 100_000, length: 0),
            NSRange(location: 100_000, length: 100_000),
            NSRange(location: renderedLength, length: 5),
            NSRange(location: sourceLength + 1, length: 0),
            NSRange(location: -1, length: 0),
            NSRange(location: -50, length: 10),
            NSRange(location: -50, length: -10),
            NSRange(location: 3, length: -1),
        ]
        for range in absurd {
            let source = model.sourceRange(for: range)
            #expect(
                source.location >= 0
                    && source.length >= 0
                    && source.location + source.length <= sourceLength,
                "rendered \(range) mapped to \(source), outside \(sourceLength)"
            )
            let rendered = model.renderedRange(for: range)
            #expect(
                rendered.location >= 0
                    && rendered.length >= 0
                    && rendered.location + rendered.length <= renderedLength,
                "source \(range) mapped to \(rendered), outside \(renderedLength)"
            )
        }
    }

    /// An empty document must render to an empty model, not to a crash and
    /// not to a stray span.
    @Test("The empty document renders to nothing")
    func emptyDocumentRendersEmpty() {
        let model = MarkdownRenderer.render("")
        #expect(model.text.isEmpty)
        #expect(model.spans.isEmpty)
        #expect(model.sourceRange(for: NSRange(location: 0, length: 0)).length == 0)
    }
}
