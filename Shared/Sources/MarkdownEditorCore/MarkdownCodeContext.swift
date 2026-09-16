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
    /// Convenience for a caller holding only the source. A caller that already
    /// has the rendered model should pass that instead and save the parse.
    public static func containing(
        _ selection: NSRange,
        in text: String
    ) -> MarkdownCodeContext {
        containing(selection, in: MarkdownRenderer.render(text))
    }

    /// The context `selection` sits in, within an already rendered `model`.
    public static func containing(
        _ selection: NSRange,
        in model: MarkdownRenderModel
    ) -> MarkdownCodeContext {
        // A fenced block is asked first: backticks written inside one are not
        // a code span, and the block is the stronger statement about what the
        // text means.
        for span in model.spans
        where span.style.isFencedCodeBlock && span.includesMarkup {
            if touches(selection, span.sourceRange, startIsInside: true) {
                return .codeBlock(span.sourceRange)
            }
        }
        for span in model.spans where span.style == .inlineCode {
            if touches(selection, span.sourceRange, startIsInside: false) {
                return .inlineCodeSpan(span.sourceRange)
            }
        }
        return .prose
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
