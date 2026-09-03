import Foundation

/// Keeps a critique's marks on the words they were written about while the
/// draft is edited underneath them.
///
/// A critique is anchored once, by finding each quoted passage in the text and
/// remembering where it was. Every keystroke after that moves the words around
/// those offsets, and an offset that is not maintained stops describing the
/// passage it was found in: the mark slides off the sentence, or swallows
/// whatever is typed next to it.
///
/// The rules below are about the second failure. The obvious implementation —
/// grow the range by whatever was inserted inside it — is right in the middle
/// of a passage and wrong at its edges, because "inside" includes both
/// boundaries. Typing a new sentence immediately after a marked one then drags
/// the mark over the new sentence, which nobody asked it to comment on.
public enum CritiqueAnchorTracking {
    /// One edit, as the editor makes it: a replacement at a location.
    public struct Edit: Equatable {
        public let location: Int
        public let removed: Int
        public let inserted: Int
        /// Whether the inserted text starts a new line. A passage does not
        /// continue across a paragraph the author has just split.
        public let insertedBreaksLine: Bool

        public init(
            location: Int,
            removed: Int,
            inserted: Int,
            insertedBreaksLine: Bool = false
        ) {
            self.location = location
            self.removed = removed
            self.inserted = inserted
            self.insertedBreaksLine = insertedBreaksLine
        }

        public var delta: Int { inserted - removed }
        public var removedEnd: Int { location + removed }
    }

    /// Where a marked passage ends up after an edit, or nil if the edit took
    /// it away.
    public static func adjust(_ range: NSRange, for edit: Edit) -> NSRange? {
        let start = range.location
        let end = range.location + range.length

        // Wholly after the passage: nothing about it moved. This is also the
        // boundary case that matters most — an edit *at* the end is after it,
        // so typing a new sentence onto the end of a marked one leaves the
        // mark on the sentence that was criticised.
        if edit.location >= end {
            return range
        }

        // Wholly before it: the passage keeps its length and slides. An
        // insertion exactly at the start counts as before, so typing in front
        // of a marked sentence pushes the mark along rather than stretching it
        // backwards over the new words.
        if edit.removedEnd <= start {
            let moved = start + edit.delta
            guard moved >= 0 else { return nil }
            return NSRange(location: moved, length: range.length)
        }

        // A line break put inside the passage ends it there. What follows is
        // a new paragraph, and a critique of one paragraph should not reach
        // into the next.
        //
        // Checked before the insert/replace split, not inside it: typing a
        // return between two words replaces the space between them, so it
        // arrives here as a one-character replacement rather than as a pure
        // insertion. Testing only insertions passed every unit test and let
        // the mark run straight across the new paragraph.
        if edit.insertedBreaksLine, edit.location > start, edit.location < end {
            return NSRange(location: start, length: edit.location - start)
        }

        // A pure insertion strictly inside. The words either side are still
        // the passage, so it grows.
        if edit.removed == 0 {
            return NSRange(location: start, length: range.length + edit.inserted)
        }

        // Otherwise the edit removed something the passage overlapped. What is
        // left of it is whatever survived on either side, joined by however
        // much was put back in between.
        let keptBefore = max(0, min(end, edit.location) - start)
        let keptAfter = max(0, end - max(start, edit.removedEnd))
        let insertedInside = edit.location >= start ? edit.inserted : 0
        let length = keptBefore + insertedInside + keptAfter
        guard length > 0 else { return nil }
        let newStart = edit.location < start
            ? edit.location + edit.inserted
            : start
        return NSRange(location: max(0, newStart), length: length)
    }

    /// The single replacement that turns `old` into `new`.
    ///
    /// Derived rather than observed. `NSTextStorage` reports edits, but the
    /// critique is told about the document as a whole — and going through the
    /// text view would tie the marks to one editor, when what moved them is
    /// the *document* changing, whoever changed it. Reverting a file on disk
    /// has to move them too.
    ///
    /// A common prefix and suffix is not a real diff and does not need to be:
    /// for one keystroke, one paste or one deletion it is exactly right, and
    /// those are what happens between two consecutive looks at the text.
    public static func edit(from old: String, to new: String) -> Edit? {
        guard old != new else { return nil }
        let a = Array(old.utf16)
        let b = Array(new.utf16)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix,
              suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }

        let removed = a.count - prefix - suffix
        let inserted = b.count - prefix - suffix
        let newline = UInt16(10)
        let carriageReturn = UInt16(13)
        let insertedText = b[prefix..<(prefix + inserted)]
        return Edit(
            location: prefix,
            removed: removed,
            inserted: inserted,
            insertedBreaksLine: insertedText.contains(newline)
                || insertedText.contains(carriageReturn)
        )
    }
}
