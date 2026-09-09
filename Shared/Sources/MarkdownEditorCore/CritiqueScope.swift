import Foundation

/// How much of the draft a critique is being asked about.
///
/// Re-reading a whole draft to find out what a new paragraph broke is slow and
/// expensive, and it throws away notes the author has not dealt with yet: a
/// re-run replaces the report, so an untouched finding from twenty minutes ago
/// comes back with a new identity, a new position in the rail, and any
/// "answered" mark on it gone. Most edits are local, so most re-runs should be
/// too.
public enum CritiqueScope: Equatable, Sendable {
    /// Read everything and replace the report.
    case whole
    /// Read everything for context, but only write findings about this passage
    /// of the *new* text, and keep the notes that were about the rest.
    case changes(NSRange)
}

/// What changed between two versions of a draft, in terms a critique can use.
public enum CritiqueChangeScope {
    /// The passage of `new` that differs from `old`, widened to whole
    /// paragraphs, or nil when nothing changed.
    ///
    /// Two decisions matter here.
    ///
    /// The first is that this collapses every edit into **one span**. The diff
    /// underneath is a common prefix and a common suffix, so editing the first
    /// and last paragraphs of a draft reports the whole draft as changed. That
    /// is more than strictly necessary and it is the safe direction to be
    /// wrong in: the alternative is a set of spans that can each be
    /// individually correct while missing that a sentence moved from one to
    /// another. Over-reading costs tokens; under-reading silently keeps notes
    /// about text that is gone.
    ///
    /// The second is that the span is widened to **whole paragraphs**. The raw
    /// diff of "the cat sat" → "the cat sat down" is the word "down", and a
    /// critique of the word "down" is worthless — it cannot see the sentence it
    /// landed in, and every quote it might return would be too small to anchor.
    /// A paragraph is the smallest unit anybody writes or judges.
    public static func changedParagraphs(from old: String, to new: String) -> NSRange? {
        guard old != new else { return nil }
        guard let edit = CritiqueAnchorTracking.edit(from: old, to: new) else {
            return nil
        }
        // The inserted text, as it sits in `new`. A pure deletion inserts
        // nothing, and still has to be reported: the paragraph it was cut from
        // is now a different paragraph and wants re-reading.
        let raw = NSRange(location: edit.location, length: edit.inserted)
        return paragraph(containing: trimmingSeparators(raw, in: new), in: new)
    }

    /// Shrinks a range past the blank lines at either end of it.
    ///
    /// Appending a paragraph inserts the separator as well as the words —
    /// "\n\nCache invalidation…" — and that separator belongs to the gap, not
    /// to either paragraph. Widening without trimming it starts the search one
    /// character into the *previous* paragraph's trailing newline, finds only
    /// one line break behind it before hitting text, and so decides the
    /// previous paragraph is part of the change too.
    ///
    /// Measured on the running app: adding a paragraph to the end of a draft
    /// swallowed the paragraph above it and retired a perfectly good note about
    /// a sentence nobody had touched. The unit tests missed it because they
    /// edited paragraphs in the middle, where the asymmetry does not show.
    ///
    /// A range that is *all* separator — pressing Return on its own — trims to
    /// nothing, and then the edit point itself is the answer: that is the
    /// paragraph being split, and it is the one to re-read.
    static func trimmingSeparators(_ range: NSRange, in text: String) -> NSRange {
        let units = Array(text.utf16)
        var start = max(0, min(range.location, units.count))
        var end = max(start, min(range.location + range.length, units.count))
        while start < end, isLineBreak(units[start]) || isSpace(units[start]) {
            start += 1
        }
        while end > start, isLineBreak(units[end - 1]) || isSpace(units[end - 1]) {
            end -= 1
        }
        guard start < end else {
            return NSRange(location: range.location, length: 0)
        }
        return NSRange(location: start, length: end - start)
    }

    /// Widens a range to the blank-line-separated blocks it touches.
    ///
    /// "Blank line" and not "newline": a Markdown list, a fenced code block and
    /// a table are each one thing to judge, and splitting them at every line
    /// break would hand the model a fragment of a table and ask what is wrong
    /// with it.
    public static func paragraph(containing range: NSRange, in text: String) -> NSRange {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return NSRange(location: 0, length: 0) }

        let clampedStart = max(0, min(range.location, units.count))
        let clampedEnd = max(clampedStart, min(range.location + range.length, units.count))

        var start = clampedStart
        while start > 0, !isBlankLineBoundary(before: start, in: units) {
            start -= 1
        }
        var end = clampedEnd
        while end < units.count, !isBlankLineBoundary(after: end, in: units) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    /// Whether a paragraph break sits immediately before `index`.
    private static func isBlankLineBoundary(before index: Int, in units: [UInt16]) -> Bool {
        // Walking back from `index`, a blank line is two line breaks with only
        // whitespace between them.
        var seenBreaks = 0
        var cursor = index - 1
        while cursor >= 0 {
            let unit = units[cursor]
            if isLineBreak(unit) {
                seenBreaks += 1
                if seenBreaks == 2 { return true }
                // A CRLF pair is one break, not two.
                if unit == 10, cursor > 0, units[cursor - 1] == 13 { cursor -= 1 }
            } else if isSpace(unit) {
                // Whitespace between two breaks does not make the line
                // non-blank.
            } else {
                return false
            }
            cursor -= 1
        }
        return true
    }

    private static func isBlankLineBoundary(after index: Int, in units: [UInt16]) -> Bool {
        var seenBreaks = 0
        var cursor = index
        while cursor < units.count {
            let unit = units[cursor]
            if isLineBreak(unit) {
                seenBreaks += 1
                if seenBreaks == 2 { return true }
                if unit == 13, cursor + 1 < units.count, units[cursor + 1] == 10 {
                    cursor += 1
                }
            } else if isSpace(unit) {
                // As above.
            } else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 10 || unit == 13
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 32 || unit == 9
    }

    /// Which of the previous notes survive a critique that only re-read part
    /// of the draft.
    ///
    /// The rule is that this run supersedes what it actually looked at, and
    /// nothing else. A note anchored inside the changed passage was about text
    /// that has just been rewritten and re-read, so the new findings replace
    /// it. A note anchored outside it describes text this run was told not to
    /// comment on, so dropping it would silently delete a criticism nobody
    /// addressed — the failure that matters here, because it looks exactly
    /// like the draft having improved.
    ///
    /// An **unanchored** note — one whose quote can no longer be found — is
    /// kept. It is tempting to treat it as dead, but its position is precisely
    /// what is unknown: it may be about a part of the draft this run never
    /// examined, and the rail already shows it as no longer pointing at
    /// anything. Keeping it leaves the author to decide; dropping it decides
    /// for them on the basis of a guess.
    ///
    /// Ranges are expected to have been moved through `noteCurrentText`
    /// already, so they address the *new* text, which is the same coordinate
    /// space as `changed`.
    public static func surviving(
        _ ranges: [NSRange?],
        changed: NSRange
    ) -> [Bool] {
        ranges.map { range in
            guard let range else { return true }
            return !intersects(range, changed)
        }
    }

    /// Whether two ranges share any text.
    ///
    /// Written out rather than using `NSIntersectionRange` because a
    /// zero-length range — a note whose passage was deleted down to nothing,
    /// or an insertion point — intersects nothing by that function's
    /// reckoning, and a note sitting exactly at the edit point is very much
    /// about the text that changed.
    static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        if a.length == 0 { return a.location >= b.location && a.location <= bEnd }
        if b.length == 0 { return b.location >= a.location && b.location <= aEnd }
        return a.location < bEnd && b.location < aEnd
    }

    /// The text of a range, for quoting back to the model.
    public static func passage(_ range: NSRange, in text: String) -> String {
        let units = Array(text.utf16)
        let start = max(0, min(range.location, units.count))
        let end = max(start, min(range.location + range.length, units.count))
        guard start < end else { return "" }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    /// Whether asking about only this passage is worth it.
    ///
    /// When the change covers nearly all of the draft there is nothing to save
    /// and something to lose: the model is asked to ignore a sliver, the merge
    /// keeps almost no old notes, and the result is a whole-document critique
    /// wearing a partial one's clothes. Below that, a partial run is honest.
    ///
    /// Also refuses a passage so short that no useful quote could come out of
    /// it — a two-word paragraph is a heading, and a critique of a heading in
    /// isolation is noise.
    public static func isWorthScoping(
        _ range: NSRange,
        in text: String,
        coverageCeiling: Double = 0.75
    ) -> Bool {
        let total = text.utf16.count
        guard total > 0, range.length > 0 else { return false }
        guard Double(range.length) / Double(total) <= coverageCeiling else {
            return false
        }
        return passage(range, in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count >= 12
    }
}
