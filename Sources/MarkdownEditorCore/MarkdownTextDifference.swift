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
}
