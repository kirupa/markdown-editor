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
            let oldPrefix = oldSource.substring(to: prefixLength)
            let newPrefix = newSource.substring(to: prefixLength)
            let oldSuffix = oldSource.substring(
                from: oldSource.length - suffixLength
            )
            let newSuffix = newSource.substring(
                from: newSource.length - suffixLength
            )
            if oldPrefix == newPrefix, oldSuffix == newSuffix {
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

        var sharedPrefixLength = 0
        let sharedLength = min(oldSource.length, newSource.length)
        while sharedPrefixLength < sharedLength,
            oldSource.character(at: sharedPrefixLength)
                == newSource.character(at: sharedPrefixLength)
        {
            sharedPrefixLength += 1
        }

        var sharedSuffixLength = 0
        while sharedSuffixLength < oldSource.length - sharedPrefixLength,
            sharedSuffixLength < newSource.length - sharedPrefixLength,
            oldSource.character(
                at: oldSource.length - sharedSuffixLength - 1
            ) == newSource.character(
                at: newSource.length - sharedSuffixLength - 1
            )
        {
            sharedSuffixLength += 1
        }

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

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
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
