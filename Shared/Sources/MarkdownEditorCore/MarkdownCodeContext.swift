import Foundation

/// Where a selection sits, as far as Markdown's *inline* syntax is concerned.
///
/// Markdown is inert inside code. `**bold**` typed into a fenced block or
/// between a code span's backticks is not emphasis — it is four asterisks and
/// a word, and every conforming renderer, including this one, shows it that
/// way. So a formatting command run there cannot do what it was asked to do:
/// the only thing it can produce is literal punctuation in the writer's code.
///
/// This is the shared answer to "what block is this offset in", derived from
/// `MarkdownRenderModel` rather than from a second scanner of its own, so the
/// commands refuse in exactly the places the reading view draws as code and
/// the two can never disagree.
///
/// Four-space indented code is deliberately **not** here. This editor's
/// renderer does not implement it — an indented line is an ordinary paragraph,
/// and emphasis typed on one is drawn as emphasis — so refusing there would
/// stop a command that visibly works. See `Contract/README.md`.
public enum MarkdownCodeContext: Equatable, Sendable {
    /// Ordinary prose: a paragraph, a heading, a list item, a block quote.
    /// Inline syntax means what it says, so every command applies.
    ///
    /// A block quote is prose. Bold inside a quote is ordinary Markdown, the
    /// renderer hides its markers there as it does anywhere else, and nothing
    /// in this file should ever refuse it.
    case prose
    /// Inside a fenced code block, whose whole source range — its own fence
    /// lines included — is carried. A caret on a fence line counts: what gets
    /// written there displaces the fence rather than styling anything.
    case codeBlock(NSRange)
    /// Inside an inline code span, whose source range — backticks included —
    /// is carried.
    case inlineCodeSpan(NSRange)

    public var isCode: Bool { self != .prose }

    /// The code the selection is in, in source offsets.
    public var sourceRange: NSRange? {
        switch self {
        case .prose: nil
        case .codeBlock(let range), .inlineCodeSpan(let range): range
        }
    }
}

extension MarkdownCodeContext {
    /// The context `selection` sits in, within `text`.
    ///
    /// Parses only the blocks the selection's two ends fall in, never the whole
    /// document — see `containing(_:spansAround:)`.
    public static func containing(
        _ selection: NSRange,
        in text: String
    ) -> MarkdownCodeContext {
        containing(selection, in: text as NSString)
    }

    /// The context `selection` sits in, within `source`, parsing only the
    /// blocks the selection's two ends fall in.
    public static func containing(
        _ selection: NSRange,
        in source: NSString
    ) -> MarkdownCodeContext {
        containing(selection) { offset in
            MarkdownFormatting.spansAroundBlock(at: offset, in: source)
        }
    }

    /// The context `selection` sits in, read from the spans of the block
    /// around a source offset — which a caller holding parsed blocks, like the
    /// incremental renderer, can answer without parsing anything.
    ///
    /// Two blocks are enough, and the answer is the one the whole document
    /// gives. The code a caret is in contains the caret. The code a selection
    /// is in overlaps it without lying inside it, and a region that does that
    /// holds the selection's first character or its last. A fence is one block
    /// and a code span never leaves its line, so the blocks those two
    /// characters fall in hold every candidate. This is what lets the toolbar
    /// ask on every caret move.
    public static func containing(
        _ selection: NSRange,
        spansAround: (Int) -> [MarkdownRenderSpan]
    ) -> MarkdownCodeContext {
        var spans = spansAround(selection.location)
        // A fence found at the start is already the answer — fences are asked
        // first, and nothing in a later block precedes it — so a selection
        // inside a long fence does not read the fence twice.
        if selection.length > 0, firstFence(touching: selection, among: spans) == nil {
            spans += spansAround(NSMaxRange(selection) - 1)
        }
        return containing(selection, among: spans)
    }

    /// The context `selection` sits in, within an already rendered `model`.
    ///
    /// Walks every span in the document. The block-scoped readings above are
    /// tested against this one.
    public static func containing(
        _ selection: NSRange,
        in model: MarkdownRenderModel
    ) -> MarkdownCodeContext {
        containing(selection, among: model.spans)
    }

    private static func containing(
        _ selection: NSRange,
        among spans: [MarkdownRenderSpan]
    ) -> MarkdownCodeContext {
        // A fenced block is asked first: backticks written inside one are not
        // a code span, and the block is the stronger statement about what the
        // text means.
        if let fence = firstFence(touching: selection, among: spans) {
            return .codeBlock(fence)
        }
        for span in spans where span.style == .inlineCode {
            if touches(selection, span.sourceRange, startIsInside: false) {
                return .inlineCodeSpan(span.sourceRange)
            }
        }
        return .prose
    }

    private static func firstFence(
        touching selection: NSRange,
        among spans: [MarkdownRenderSpan]
    ) -> NSRange? {
        spans.first { span in
            span.style.isFencedCodeBlock
                && span.includesMarkup
                && touches(selection, span.sourceRange, startIsInside: true)
        }?.sourceRange
    }

    /// Whether `selection` is code rather than the prose around it.
    ///
    /// A selection that *contains* the whole region is prose holding a piece
    /// of code — bolding `` `x` `` along with the words either side of it is
    /// both legal and useful — so that case is let through. A selection that
    /// overlaps the region without containing it is not: it would put one
    /// marker inside the code and its partner outside, which is the worst of
    /// the three outcomes and never what was meant.
    ///
    /// `startIsInside` is the asymmetry between the two kinds of code. A caret
    /// at the first character of a fence line is inside the block, because
    /// what gets written there displaces the fence. A caret at the first
    /// backtick of a code span is in front of it, and what gets written there
    /// lands in the prose, correctly.
    private static func touches(
        _ selection: NSRange,
        _ region: NSRange,
        startIsInside: Bool
    ) -> Bool {
        let lower = startIsInside ? region.location : region.location + 1
        let upper = NSMaxRange(region)
        guard upper > lower else {
            return false
        }

        guard selection.length > 0 else {
            return selection.location >= lower && selection.location < upper
        }
        guard NSIntersectionRange(selection, region).length > 0 else {
            return false
        }
        let containsRegion = selection.location <= region.location
            && upper <= NSMaxRange(selection)
        return !containsRegion
    }
}

extension MarkdownRenderStyle {
    /// A fenced block, whatever language it was tagged with.
    var isFencedCodeBlock: Bool {
        if case .codeBlock = self {
            return true
        }
        return false
    }
}
