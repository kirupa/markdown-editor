import Foundation

/// Where each finding's quoted passage actually sits in the document.
///
/// A critique names a passage by quoting it. Highlighting that passage means
/// finding the quote again in the text — which sounds like one call to
/// `range(of:)` and is not, for three reasons this handles:
///
///  * A model re-types a quote as often as it copies one. Curly quotes become
///    straight, a line break inside a sentence becomes a space, a run of
///    spaces collapses. The passage is still there; the bytes are not.
///  * A short quote can occur several times. The finding says which one it
///    means — "paragraph 3" — and using that beats highlighting the first hit.
///  * Sometimes the quote is simply not in the draft, because the model
///    paraphrased. That has to be visible rather than silently anchored to
///    something that merely looks similar.
public enum CritiqueAnchoring {
    /// A finding, and where it points.
    public struct Anchor: Equatable, Sendable {
        public let findingID: UUID
        /// Nil when the quote could not be found: the card is still shown, and
        /// says so, rather than highlighting a passage the critique never
        /// mentioned.
        public let range: NSRange?

        public init(findingID: UUID, range: NSRange?) {
            self.findingID = findingID
            self.range = range
        }

        public var isAnchored: Bool { range != nil }
    }

    /// Anchors every finding, keeping the order they arrived in.
    public static func anchor(
        _ findings: [CritiqueFinding],
        in text: String
    ) -> [Anchor] {
        // Two findings can quote the same words. Each should get its own
        // occurrence where the text offers one, so the rail does not stack two
        // cards on one highlight while an identical passage sits unmarked.
        var claimed: [NSRange] = []
        return findings.map { finding in
            let range = self.range(
                for: finding,
                in: text,
                avoiding: claimed
            )
            if let range { claimed.append(range) }
            return Anchor(findingID: finding.id, range: range)
        }
    }

    /// Where one finding's quote sits, preferring an unclaimed occurrence.
    public static func range(
        for finding: CritiqueFinding,
        in text: String,
        avoiding claimed: [NSRange] = []
    ) -> NSRange? {
        let quote = finding.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }

        let candidates = occurrences(of: quote, in: text)
        guard !candidates.isEmpty else { return nil }

        let unclaimed = candidates.filter { candidate in
            !claimed.contains { NSIntersectionRange($0, candidate).length > 0 }
        }
        let usable = unclaimed.isEmpty ? candidates : unclaimed
        return choose(from: usable, using: finding.location, in: text)
    }

    // MARK: - Finding the words

    /// Every place `quote` appears, exactly or allowing for retyping.
    ///
    /// The exact pass runs first and wins outright when it finds anything: a
    /// verbatim match is the strongest evidence available, and falling through
    /// to a looser comparison after one succeeds could only make things worse.
    static func occurrences(of quote: String, in text: String) -> [NSRange] {
        let exact = exactOccurrences(of: quote, in: text)
        if !exact.isEmpty { return exact }
        return relaxedOccurrences(of: quote, in: text)
    }

    private static func exactOccurrences(
        of quote: String,
        in text: String
    ) -> [NSRange] {
        let source = text as NSString
        var found: [NSRange] = []
        var searchFrom = 0
        while searchFrom < source.length {
            let remaining = NSRange(
                location: searchFrom,
                length: source.length - searchFrom
            )
            let hit = source.range(of: quote, options: [], range: remaining)
            guard hit.location != NSNotFound else { break }
            found.append(hit)
            searchFrom = hit.location + max(1, hit.length)
        }
        return found
    }

    /// Matches the quote against the text ignoring how whitespace and quote
    /// marks were typed, then reports the range in the *original* text.
    ///
    /// Done by folding both sides to a canonical form while keeping, for every
    /// folded character, the offset it came from. The match is performed on the
    /// folded text and the answer is translated back, so the highlight lands on
    /// real characters rather than on an approximation of them.
    private static func relaxedOccurrences(
        of quote: String,
        in text: String
    ) -> [NSRange] {
        let foldedText = fold(text)
        let foldedQuote = fold(quote)
        guard !foldedQuote.value.isEmpty else { return [] }

        let haystack = foldedText.value as NSString
        let needle = foldedQuote.value
        var found: [NSRange] = []
        var searchFrom = 0
        while searchFrom < haystack.length {
            let remaining = NSRange(
                location: searchFrom,
                length: haystack.length - searchFrom
            )
            let hit = haystack.range(of: needle, options: [], range: remaining)
            guard hit.location != NSNotFound, hit.length > 0 else { break }
            let startOffset = foldedText.offsets[hit.location]
            let lastOffset = foldedText.offsets[hit.location + hit.length - 1]
            found.append(
                NSRange(
                    location: startOffset,
                    length: lastOffset - startOffset + 1
                )
            )
            searchFrom = hit.location + 1
        }
        return found
    }

    /// A canonical form, plus where each of its characters came from.
    struct Folded {
        let value: String
        /// `offsets[i]` is the UTF-16 offset in the original text that
        /// `value[i]` came from.
        let offsets: [Int]
    }

    /// Collapses whitespace runs to one space and normalises the punctuation a
    /// model is most likely to re-type: curly quotes, dashes, and ellipses.
    static func fold(_ text: String) -> Folded {
        let source = text as NSString
        var value = ""
        var offsets: [Int] = []
        var lastWasSpace = false

        for offset in 0..<source.length {
            let character = Character(
                UnicodeScalar(source.character(at: offset)) ?? " "
            )
            if character.isWhitespace {
                // A run of any whitespace — including the newline inside a
                // wrapped sentence — becomes a single space, because that is
                // how a model reproduces it.
                if lastWasSpace { continue }
                value.append(" ")
                offsets.append(offset)
                lastWasSpace = true
                continue
            }
            lastWasSpace = false
            value.append(canonical(character))
            offsets.append(offset)
        }
        return Folded(value: value, offsets: offsets)
    }

    private static func canonical(_ character: Character) -> Character {
        switch character {
        case "\u{2018}", "\u{2019}", "\u{201B}", "\u{2032}": return "'"
        case "\u{201C}", "\u{201D}", "\u{201F}", "\u{2033}": return "\""
        case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}":
            return "-"
        case "\u{00A0}": return " "
        default:
            return Character(character.lowercased())
        }
    }

    // MARK: - Choosing between several matches

    /// Picks the occurrence the finding's location points at.
    ///
    /// The skill writes locations like "Opening, paragraph 2" or
    /// "paragraph 4". When a number is there, it is a paragraph index counted
    /// from the top of the draft, so the occurrence inside that paragraph is
    /// the one meant. With nothing to go on, the first is as good a guess as
    /// any — and better than the last.
    static func choose(
        from candidates: [NSRange],
        using location: String,
        in text: String
    ) -> NSRange? {
        guard candidates.count > 1 else { return candidates.first }
        guard let wanted = paragraphNumber(in: location) else {
            return candidates.first
        }
        let paragraphs = paragraphRanges(in: text)
        guard wanted >= 1, wanted <= paragraphs.count else {
            return candidates.first
        }
        let target = paragraphs[wanted - 1]
        return candidates.first { NSIntersectionRange($0, target).length > 0 }
            ?? candidates.first
    }

    /// The paragraph number named in a location string, if any.
    static func paragraphNumber(in location: String) -> Int? {
        let lowered = location.lowercased()
        guard let keyword = lowered.range(of: "paragraph") else { return nil }
        let after = lowered[keyword.upperBound...]
        let digits = after.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// The non-empty blocks of the draft, in order.
    ///
    /// Counted the way a reader counts them — blank-line separated blocks —
    /// rather than by newline, so a paragraph that wraps is still one
    /// paragraph and the numbers in a critique line up with the text.
    static func paragraphRanges(in text: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        var start: Int?
        var blankRunStart: Int?

        var index = 0
        while index < source.length {
            let lineRange = source.lineRange(for: NSRange(location: index, length: 0))
            let line = source.substring(with: lineRange)
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                if let begin = start, let stop = blankRunStart {
                    ranges.append(NSRange(location: begin, length: stop - begin))
                    start = nil
                }
                blankRunStart = nil
            } else {
                if start == nil { start = lineRange.location }
                blankRunStart = NSMaxRange(lineRange)
            }
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        if let begin = start {
            ranges.append(
                NSRange(
                    location: begin,
                    length: (blankRunStart ?? source.length) - begin
                )
            )
        }
        return ranges
    }
}
