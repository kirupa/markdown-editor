import Foundation

public struct MarkdownTextReplacement: Equatable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

public enum MarkdownTextDifference {
    public static func replacement(
        from oldText: String,
        to newText: String,
        replacing requestedRange: NSRange
    ) -> MarkdownTextReplacement {
        let oldSource = oldText as NSString
        let newSource = newText as NSString
        let oldRange = clamped(requestedRange, to: oldSource.length)
        let prefixLength = oldRange.location
        let suffixLength = oldSource.length - NSMaxRange(oldRange)

        if newSource.length >= prefixLength + suffixLength {
            let keptSuffixStart = oldSource.length - suffixLength
            if matches(
                oldSource,
                newSource,
                oldStart: 0,
                newStart: 0,
                length: prefixLength
            ), matches(
                oldSource,
                newSource,
                oldStart: keptSuffixStart,
                newStart: newSource.length - suffixLength,
                length: suffixLength
            ) {
                return MarkdownTextReplacement(
                    range: oldRange,
                    replacement: newSource.substring(
                        with: NSRange(
                            location: prefixLength,
                            length: newSource.length
                                - prefixLength
                                - suffixLength
                        )
                    )
                )
            }
        }

        return minimalReplacement(from: oldText, to: newText)
    }

    /// The smallest replacement that turns one document into the other.
    ///
    /// Used when nobody can say what changed — an undo, a formatting command,
    /// a file rewritten by another app. Finding the difference is what lets
    /// those re-render the part of the document that moved instead of all of
    /// it, so it is worth doing properly rather than assuming the worst.
    public static func minimalReplacement(
        from oldText: String,
        to newText: String
    ) -> MarkdownTextReplacement {
        let oldSource = oldText as NSString
        let newSource = newText as NSString

        let sharedPrefixLength = sharedPrefix(oldSource, newSource)
        let sharedSuffixLength = sharedSuffix(
            oldSource,
            newSource,
            after: sharedPrefixLength
        )

        return MarkdownTextReplacement(
            range: NSRange(
                location: sharedPrefixLength,
                length: oldSource.length
                    - sharedPrefixLength
                    - sharedSuffixLength
            ),
            replacement: newSource.substring(
                with: NSRange(
                    location: sharedPrefixLength,
                    length: newSource.length
                        - sharedPrefixLength
                        - sharedSuffixLength
                )
            )
        )
    }

    private static func sharedPrefix(
        _ oldSource: NSString,
        _ newSource: NSString
    ) -> Int {
        let limit = min(oldSource.length, newSource.length)
        var shared = 0
        withCharacterWindows(oldSource, newSource) { old, new, window in
            while shared < limit {
                let count = min(window, limit - shared)
                oldSource.getCharacters(
                    old,
                    range: NSRange(location: shared, length: count)
                )
                newSource.getCharacters(
                    new,
                    range: NSRange(location: shared, length: count)
                )
                var index = 0
                while index < count, old[index] == new[index] {
                    index += 1
                }
                shared += index
                if index < count { return }
            }
        }
        return shared
    }

    private static func sharedSuffix(
        _ oldSource: NSString,
        _ newSource: NSString,
        after prefix: Int
    ) -> Int {
        let limit = min(
            oldSource.length - prefix,
            newSource.length - prefix
        )
        var shared = 0
        withCharacterWindows(oldSource, newSource) { old, new, window in
            while shared < limit {
                let count = min(window, limit - shared)
                oldSource.getCharacters(
                    old,
                    range: NSRange(
                        location: oldSource.length - shared - count,
                        length: count
                    )
                )
                newSource.getCharacters(
                    new,
                    range: NSRange(
                        location: newSource.length - shared - count,
                        length: count
                    )
                )
                var index = 0
                while index < count,
                    old[count - 1 - index] == new[count - 1 - index]
                {
                    index += 1
                }
                shared += index
                if index < count { return }
            }
        }
        return shared
    }

    /// Two scratch windows, so a comparison reads the strings out in blocks
    /// rather than one `character(at:)` message at a time.
    private static func withCharacterWindows(
        _ oldSource: NSString,
        _ newSource: NSString,
        _ body: (
            UnsafeMutablePointer<unichar>,
            UnsafeMutablePointer<unichar>,
            Int
        ) -> Void
    ) {
        let window = min(
            4_096,
            max(1, max(oldSource.length, newSource.length))
        )
        var old = [unichar](repeating: 0, count: window)
        var new = [unichar](repeating: 0, count: window)
        old.withUnsafeMutableBufferPointer { oldBuffer in
            new.withUnsafeMutableBufferPointer { newBuffer in
                body(
                    oldBuffer.baseAddress!,
                    newBuffer.baseAddress!,
                    window
                )
            }
        }
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }

    /// Whether two stretches of two strings hold the same characters.
    ///
    /// Read out a window at a time rather than by cutting substrings. The
    /// substrings were the head and the tail of the document, so confirming
    /// that an edit was where the caller said it was allocated the document
    /// twice over — on a five megabyte file, twenty megabytes thrown away for
    /// a question answered with a comparison.
    private static func matches(
        _ oldSource: NSString,
        _ newSource: NSString,
        oldStart: Int,
        newStart: Int,
        length: Int
    ) -> Bool {
        guard length > 0 else { return true }
        let window = 4_096
        var oldBuffer = [unichar](repeating: 0, count: min(window, length))
        var newBuffer = [unichar](repeating: 0, count: min(window, length))
        var copied = 0
        while copied < length {
            let count = min(window, length - copied)
            oldSource.getCharacters(
                &oldBuffer,
                range: NSRange(location: oldStart + copied, length: count)
            )
            newSource.getCharacters(
                &newBuffer,
                range: NSRange(location: newStart + copied, length: count)
            )
            for index in 0..<count where oldBuffer[index] != newBuffer[index] {
                return false
            }
            copied += count
        }
        return true
    }

    /// Where a selection ends up after the text is replaced wholesale.
    ///
    /// Reloading a file another app rewrote should not fling the caret to the
    /// top of the document; someone reading paragraph nine wants to still be
    /// at paragraph nine. Nothing here knows what the edit *was*, so the
    /// unchanged head and tail stand in for it: anything before the first
    /// difference keeps its offset, anything after the last difference keeps
    /// its distance from the end, and a selection inside the changed region
    /// has nowhere faithful to land and collapses to the end of that region.
    public static func mappedSelection(
        _ selection: NSRange,
        from oldText: String,
        to newText: String
    ) -> NSRange {
        let oldSource = oldText as NSString
        let newSource = newText as NSString
        let range = clamped(selection, to: oldSource.length)

        var prefix = 0
        let shorter = min(oldSource.length, newSource.length)
        while prefix < shorter,
            oldSource.character(at: prefix) == newSource.character(at: prefix)
        {
            prefix += 1
        }

        var suffix = 0
        while suffix < oldSource.length - prefix,
            suffix < newSource.length - prefix,
            oldSource.character(at: oldSource.length - suffix - 1)
                == newSource.character(at: newSource.length - suffix - 1)
        {
            suffix += 1
        }

        // Both ends of the selection move independently, so that a selection
        // straddling the change keeps whichever end the change did not touch.
        let start = mappedOffset(
            range.location,
            oldLength: oldSource.length,
            newLength: newSource.length,
            prefix: prefix,
            suffix: suffix
        )
        let end = mappedOffset(
            NSMaxRange(range),
            oldLength: oldSource.length,
            newLength: newSource.length,
            prefix: prefix,
            suffix: suffix
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func mappedOffset(
        _ offset: Int,
        oldLength: Int,
        newLength: Int,
        prefix: Int,
        suffix: Int
    ) -> Int {
        if offset <= prefix {
            return offset
        }
        if offset >= oldLength - suffix {
            return newLength - (oldLength - offset)
        }
        return max(prefix, newLength - suffix)
    }
}
