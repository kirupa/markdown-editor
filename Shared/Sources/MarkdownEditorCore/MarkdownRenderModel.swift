import Foundation

public enum MarkdownRenderStyle: Equatable {
    case heading(Int)
    case bold
    case italic
    case underline
    case strikethrough
    case inlineCode
    case codeBlock(String?)
    case quote
    case bulletedList
    case numberedList
    case taskList(checked: Bool)
    case link(destination: String)
    /// `width` and `height` are non-nil only for the HTML form, which is the
    /// only one that can carry a size. See `MarkdownImageTag`.
    case image(
        altText: String,
        destination: String,
        width: Int? = nil,
        height: Int? = nil
    )
    case horizontalRule
    case escaped
}

public struct MarkdownRenderSpan: Equatable {
    public let style: MarkdownRenderStyle
    public let renderedRange: NSRange
    public let sourceRange: NSRange
    public let includesMarkup: Bool
    public let isAtomic: Bool

    public init(
        style: MarkdownRenderStyle,
        renderedRange: NSRange,
        sourceRange: NSRange,
        includesMarkup: Bool = false,
        isAtomic: Bool = false
    ) {
        self.style = style
        self.renderedRange = renderedRange
        self.sourceRange = sourceRange
        self.includesMarkup = includesMarkup
        self.isAtomic = isAtomic
    }
}

public struct MarkdownRenderModel: Equatable {
    public let text: String
    public let spans: [MarkdownRenderSpan]

    private let lowerSourceOffsets: [Int]
    private let upperSourceOffsets: [Int]

    fileprivate init(
        text: String,
        spans: [MarkdownRenderSpan],
        lowerSourceOffsets: [Int],
        upperSourceOffsets: [Int]
    ) {
        self.text = text
        self.spans = spans
        self.lowerSourceOffsets = lowerSourceOffsets
        self.upperSourceOffsets = upperSourceOffsets
    }

    public func sourceRange(
        for renderedRange: NSRange,
        includingMarkup: Bool = false
    ) -> NSRange {
        let renderedLength = (text as NSString).length
        let location = min(max(0, renderedRange.location), renderedLength)
        let length = min(
            max(0, renderedRange.length),
            renderedLength - location
        )
        let clampedRange = NSRange(location: location, length: length)
        guard clampedRange.length > 0 else {
            return NSRange(
                location: upperSourceOffsets[location],
                length: 0
            )
        }

        var sourceStart = upperSourceOffsets[location]
        var sourceEnd = lowerSourceOffsets[NSMaxRange(clampedRange)]
        for span in spans {
            if span.isAtomic,
                NSIntersectionRange(
                    clampedRange,
                    span.renderedRange
                ).length > 0
            {
                sourceStart = min(sourceStart, span.sourceRange.location)
                sourceEnd = max(sourceEnd, NSMaxRange(span.sourceRange))
            } else if includingMarkup,
                span.includesMarkup,
                span.renderedRange.length > 0,
                clampedRange.location <= span.renderedRange.location,
                NSMaxRange(clampedRange) >= NSMaxRange(span.renderedRange)
            {
                sourceStart = min(sourceStart, span.sourceRange.location)
                sourceEnd = max(sourceEnd, NSMaxRange(span.sourceRange))
            }
        }

        return NSRange(
            location: sourceStart,
            length: max(0, sourceEnd - sourceStart)
        )
    }

    public func renderedRange(for sourceRange: NSRange) -> NSRange {
        let sourceStart = max(0, sourceRange.location)
        let sourceEnd = max(sourceStart, NSMaxRange(sourceRange))
        let renderedStart = renderedOffset(
            for: sourceStart,
            offsets: upperSourceOffsets
        )
        guard sourceRange.length > 0 else {
            return NSRange(location: renderedStart, length: 0)
        }
        let renderedEnd = renderedOffset(
            for: sourceEnd,
            offsets: lowerSourceOffsets
        )
        return NSRange(
            location: renderedStart,
            length: max(0, renderedEnd - renderedStart)
        )
    }

    private func renderedOffset(
        for sourceOffset: Int,
        offsets: [Int]
    ) -> Int {
        for (index, mappedOffset) in offsets.enumerated()
        where mappedOffset >= sourceOffset {
            return index
        }
        return max(0, offsets.count - 1)
    }
}

public enum MarkdownRenderer {
    public static func render(_ markdown: String) -> MarkdownRenderModel {
        Parser(markdown: markdown).render()
    }
}

private final class Parser {
    private static let headingExpression = expression(
        #"^([ \t]{0,3})(#{1,6})[ \t]+"#
    )
    private static let quoteExpression = expression(
        #"^([ \t]*>[ \t]?)"#
    )
    private static let taskExpression = expression(
        #"^([ \t]*)([-+*][ \t]+\[([ xX])\])([ \t]+)"#
    )
    private static let bulletExpression = expression(
        #"^([ \t]*)([-+*])([ \t]+)"#
    )
    private static let numberedExpression = expression(
        #"^([ \t]*)(\d+[.)])([ \t]+)"#
    )

    private let source: NSString
    private let builder: RenderBuilder

    init(markdown: String) {
        source = markdown as NSString
        builder = RenderBuilder(source: source)
    }

    func render() -> MarkdownRenderModel {
        var location = 0
        var codeFence: CodeFence?

        while location < source.length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            source.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let contentRange = NSRange(
                location: lineStart,
                length: contentsEnd - lineStart
            )
            let newlineRange = NSRange(
                location: contentsEnd,
                length: lineEnd - contentsEnd
            )
            let line = source.substring(with: contentRange)

            if let activeFence = codeFence {
                if isClosingFence(line, for: activeFence) {
                    builder.advanceSource(to: lineEnd)
                    let renderedRange = NSRange(
                        location: activeFence.renderedStart,
                        length: builder.length - activeFence.renderedStart
                    )
                    builder.addSpan(
                        .codeBlock(activeFence.language),
                        renderedRange: renderedRange,
                        sourceRange: NSRange(
                            location: activeFence.sourceStart,
                            length: lineEnd - activeFence.sourceStart
                        ),
                        includesMarkup: true
                    )
                    codeFence = nil
                } else {
                    let renderedStart = builder.length
                    builder.appendSource(contentRange)
                    builder.appendSource(newlineRange)
                    builder.addSpan(
                        .codeBlock(activeFence.language),
                        renderedRange: NSRange(
                            location: renderedStart,
                            length: builder.length - renderedStart
                        ),
                        sourceRange: NSRange(
                            location: contentRange.location,
                            length: lineEnd - contentRange.location
                        )
                    )
                }
            } else if let openingFence = openingFence(in: line) {
                builder.advanceSource(to: lineEnd)
                codeFence = CodeFence(
                    marker: openingFence.marker,
                    language: openingFence.language,
                    sourceStart: lineStart,
                    renderedStart: builder.length
                )
            } else {
                renderLine(contentRange)
                builder.appendSource(newlineRange)
            }

            location = max(lineEnd, location + 1)
        }

        if let codeFence {
            let renderedRange = NSRange(
                location: codeFence.renderedStart,
                length: builder.length - codeFence.renderedStart
            )
            builder.addSpan(
                .codeBlock(codeFence.language),
                renderedRange: renderedRange,
                sourceRange: NSRange(
                    location: codeFence.sourceStart,
                    length: source.length - codeFence.sourceStart
                ),
                includesMarkup: true
            )
        }

        builder.advanceSource(to: source.length)
        return builder.model()
    }

    private func renderLine(_ lineRange: NSRange) {
        let line = source.substring(with: lineRange)
        let renderedLineStart = builder.length
        if isHorizontalRule(line) {
            let renderedRange = builder.appendSynthetic(
                "—",
                sourceRange: lineRange
            )
            builder.addSpan(
                .horizontalRule,
                renderedRange: renderedRange,
                sourceRange: lineRange,
                includesMarkup: true,
                isAtomic: true
            )
            return
        }

        var contentStart = lineRange.location
        var headingLevel: Int?
        var blockStyle: MarkdownRenderStyle?
        var blockIncludesMarkup = false

        if let heading = match(Self.headingExpression, in: lineRange) {
            headingLevel = heading[2].length
            contentStart = NSMaxRange(heading[0])
            blockIncludesMarkup = true
        } else if let quote = match(Self.quoteExpression, in: lineRange) {
            contentStart = NSMaxRange(quote[1])
            blockStyle = .quote
            blockIncludesMarkup = true
        }

        let remainingRange = NSRange(
            location: contentStart,
            length: NSMaxRange(lineRange) - contentStart
        )
        var listStyle: MarkdownRenderStyle?
        if let task = match(Self.taskExpression, in: remainingRange) {
            let markerRange = NSRange(
                location: task[2].location,
                length: task[2].length
            )
            let checked = source.substring(with: task[3])
                .lowercased() == "x"
            builder.advanceSource(to: markerRange.location)
            let renderedMarker = builder.appendSynthetic(
                checked ? "☑" : "☐",
                sourceRange: markerRange
            )
            builder.addSpan(
                .taskList(checked: checked),
                renderedRange: renderedMarker,
                sourceRange: markerRange,
                isAtomic: true
            )
            builder.appendSource(task[4])
            contentStart = NSMaxRange(task[0])
            listStyle = .taskList(checked: checked)
        } else if let bullet = match(
            Self.bulletExpression,
            in: remainingRange
        ) {
            builder.advanceSource(to: bullet[2].location)
            let renderedMarker = builder.appendSynthetic(
                "•",
                sourceRange: bullet[2]
            )
            builder.addSpan(
                .bulletedList,
                renderedRange: renderedMarker,
                sourceRange: bullet[2],
                isAtomic: true
            )
            builder.appendSource(bullet[3])
            contentStart = NSMaxRange(bullet[0])
            listStyle = .bulletedList
        } else if let numbered = match(
            Self.numberedExpression,
            in: remainingRange
        ) {
            builder.advanceSource(to: numbered[2].location)
            builder.appendSource(numbered[2])
            builder.appendSource(numbered[3])
            contentStart = NSMaxRange(numbered[0])
            listStyle = .numberedList
        }

        builder.advanceSource(to: contentStart)
        let renderedStart = builder.length
        renderInline(
            NSRange(
                location: contentStart,
                length: NSMaxRange(lineRange) - contentStart
            )
        )
        let renderedContentRange = NSRange(
            location: renderedStart,
            length: builder.length - renderedStart
        )

        if let headingLevel {
            builder.addSpan(
                .heading(headingLevel),
                renderedRange: renderedContentRange,
                sourceRange: lineRange,
                includesMarkup: blockIncludesMarkup
            )
        } else if let blockStyle {
            builder.addSpan(
                blockStyle,
                renderedRange: renderedContentRange,
                sourceRange: lineRange,
                includesMarkup: blockIncludesMarkup
            )
        }

        if let listStyle {
            let lineRenderedRange = NSRange(
                location: renderedLineStart,
                length: builder.length - renderedLineStart
            )
            builder.addSpan(
                listStyle,
                renderedRange: lineRenderedRange,
                sourceRange: lineRange
            )
        }
    }

    private func renderInline(_ range: NSRange) {
        var location = range.location
        let end = NSMaxRange(range)

        while location < end {
            if source.character(at: location) == 0x5C,
                location + 1 < end,
                isMarkdownEscapable(
                    source.character(at: location + 1)
                )
            {
                let sourceRange = NSRange(location: location, length: 2)
                builder.advanceSource(to: location + 1)
                let renderedStart = builder.length
                builder.appendSource(
                    NSRange(location: location + 1, length: 1)
                )
                builder.advanceSource(to: location + 2)
                builder.addSpan(
                    .escaped,
                    renderedRange: NSRange(
                        location: renderedStart,
                        length: builder.length - renderedStart
                    ),
                    sourceRange: sourceRange,
                    includesMarkup: true,
                    isAtomic: true
                )
                location += 2
                continue
            }

            if source.character(at: location) == 0x3C,               // <
               let tag = MarkdownImageTag.parse(
                   source,
                   at: location,
                   end: end
               )
            {
                let fullRange = NSRange(
                    location: location,
                    length: tag.end - location
                )
                builder.advanceSource(to: location)
                let renderedRange = builder.appendSynthetic(
                    "\u{FFFC}",
                    sourceRange: fullRange
                )
                builder.addSpan(
                    .image(
                        altText: tag.altText,
                        destination: tag.destination,
                        width: tag.width,
                        height: tag.height
                    ),
                    renderedRange: renderedRange,
                    sourceRange: fullRange,
                    includesMarkup: true,
                    isAtomic: true
                )
                location = tag.end
                continue
            }

            if let image = linkToken(at: location, end: end, isImage: true) {
                builder.advanceSource(to: image.fullRange.location)
                let renderedRange = builder.appendSynthetic(
                    "\u{FFFC}",
                    sourceRange: image.fullRange
                )
                builder.addSpan(
                    .image(
                        altText: source.substring(with: image.labelRange),
                        destination: source.substring(
                            with: image.destinationRange
                        )
                    ),
                    renderedRange: renderedRange,
                    sourceRange: image.fullRange,
                    includesMarkup: true,
                    isAtomic: true
                )
                location = NSMaxRange(image.fullRange)
                continue
            }

            if let link = linkToken(at: location, end: end, isImage: false) {
                builder.advanceSource(to: link.labelRange.location)
                let renderedStart = builder.length
                renderInline(link.labelRange)
                let renderedRange = NSRange(
                    location: renderedStart,
                    length: builder.length - renderedStart
                )
                builder.advanceSource(to: NSMaxRange(link.fullRange))
                builder.addSpan(
                    .link(
                        destination: source.substring(
                            with: link.destinationRange
                        )
                    ),
                    renderedRange: renderedRange,
                    sourceRange: link.fullRange,
                    includesMarkup: true
                )
                location = NSMaxRange(link.fullRange)
                continue
            }

            if parseCodeSpan(at: location, end: end) {
                location = parsedTokenEnd
                continue
            }

            if parseDelimited(
                opening: "<u>",
                closing: "</u>",
                styles: [.underline],
                at: location,
                end: end,
                parseContents: true
            ) {
                location = parsedTokenEnd
                continue
            }

            if parseDelimited(
                opening: "***",
                closing: "***",
                styles: [.bold, .italic],
                at: location,
                end: end,
                parseContents: true
            ) {
                location = parsedTokenEnd
                continue
            }

            if parseDelimited(
                opening: "___",
                closing: "___",
                styles: [.bold, .italic],
                at: location,
                end: end,
                parseContents: true
            ) {
                location = parsedTokenEnd
                continue
            }

            let delimiters: [
                (String, String, [MarkdownRenderStyle], Bool)
            ] = [
                ("**", "**", [.bold], true),
                ("__", "__", [.bold], true),
                ("~~", "~~", [.strikethrough], true),
                ("*", "*", [.italic], true),
                ("_", "_", [.italic], true)
            ]
            var parsed = false
            for delimiter in delimiters where parseDelimited(
                opening: delimiter.0,
                closing: delimiter.1,
                styles: delimiter.2,
                at: location,
                end: end,
                parseContents: delimiter.3
            ) {
                location = parsedTokenEnd
                parsed = true
                break
            }
            if parsed {
                continue
            }

            let runStart = location
            location += 1
            while location < end,
                !isPotentialInlineMarker(source.character(at: location))
            {
                location += 1
            }
            builder.appendSource(
                NSRange(location: runStart, length: location - runStart)
            )
        }
    }

    private var parsedTokenEnd = 0

    private func parseCodeSpan(at location: Int, end: Int) -> Bool {
        guard source.character(at: location) == 0x60 else {
            return false
        }

        var openingLength = 0
        while location + openingLength < end,
            source.character(at: location + openingLength) == 0x60
        {
            openingLength += 1
        }
        var closingRange = NSRange(location: NSNotFound, length: 0)
        var searchLocation = location + openingLength
        while searchLocation < end {
            guard source.character(at: searchLocation) == 0x60 else {
                searchLocation += 1
                continue
            }
            let runStart = searchLocation
            while searchLocation < end,
                source.character(at: searchLocation) == 0x60
            {
                searchLocation += 1
            }
            let runLength = searchLocation - runStart
            if runLength == openingLength {
                closingRange = NSRange(
                    location: runStart,
                    length: runLength
                )
                break
            }
        }

        guard closingRange.location != NSNotFound,
            closingRange.location > location + openingLength
        else {
            return false
        }

        let contentRange = NSRange(
            location: location + openingLength,
            length: closingRange.location - location - openingLength
        )
        var displayedContentRange = contentRange
        if contentRange.length >= 2,
            source.character(at: contentRange.location) == 0x20,
            source.character(at: NSMaxRange(contentRange) - 1) == 0x20
        {
            let content = source.substring(with: contentRange)
            if !content.allSatisfy(\.isWhitespace) {
                displayedContentRange = NSRange(
                    location: contentRange.location + 1,
                    length: contentRange.length - 2
                )
            }
        }
        let fullRange = NSRange(
            location: location,
            length: NSMaxRange(closingRange) - location
        )
        builder.advanceSource(to: displayedContentRange.location)
        let renderedStart = builder.length
        builder.appendSource(displayedContentRange)
        let renderedRange = NSRange(
            location: renderedStart,
            length: builder.length - renderedStart
        )
        builder.advanceSource(to: NSMaxRange(fullRange))
        builder.addSpan(
            .inlineCode,
            renderedRange: renderedRange,
            sourceRange: fullRange,
            includesMarkup: true
        )
        parsedTokenEnd = NSMaxRange(fullRange)
        return true
    }

    private func parseDelimited(
        opening: String,
        closing: String,
        styles: [MarkdownRenderStyle],
        at location: Int,
        end: Int,
        parseContents: Bool
    ) -> Bool {
        let openingLength = (opening as NSString).length
        guard location + openingLength < end,
            source.substring(
                with: NSRange(location: location, length: openingLength)
            ) == opening,
            isMaximalDelimiterRun(
                NSRange(location: location, length: openingLength),
                delimiter: opening
            )
        else {
            return false
        }

        if usesEmphasisBoundaries(opening) {
            let nextLocation = location + openingLength
            guard !isWhitespace(at: nextLocation) else {
                return false
            }
            if opening.hasPrefix("_"), location > 0,
                isWordCharacter(at: location - 1),
                isWordCharacter(at: nextLocation)
            {
                return false
            }
        }

        var closingRange = NSRange(location: NSNotFound, length: 0)
        var searchLocation = location + openingLength
        while searchLocation < end {
            let candidate = source.range(
                of: closing,
                options: [],
                range: NSRange(
                    location: searchLocation,
                    length: end - searchLocation
                )
            )
            guard candidate.location != NSNotFound else {
                break
            }
            if isEscaped(candidate.location) {
                searchLocation = NSMaxRange(candidate)
                continue
            }
            if !isMaximalDelimiterRun(
                candidate,
                delimiter: closing
            ) {
                searchLocation = NSMaxRange(candidate)
                continue
            }

            let nextLocation = NSMaxRange(candidate)
            let hasValidBoundary = !usesEmphasisBoundaries(closing)
                || (
                    candidate.location > 0
                        && !isWhitespace(at: candidate.location - 1)
                        && !(
                            closing.hasPrefix("_")
                                && isWordCharacter(
                                    at: candidate.location - 1
                                )
                                && nextLocation < end
                                && isWordCharacter(at: nextLocation)
                        )
                )
            if hasValidBoundary {
                closingRange = candidate
                break
            }
            searchLocation = NSMaxRange(candidate)
        }

        guard closingRange.location != NSNotFound,
            closingRange.location > location + openingLength
        else {
            return false
        }

        let contentRange = NSRange(
            location: location + openingLength,
            length: closingRange.location - location - openingLength
        )
        let fullRange = NSRange(
            location: location,
            length: NSMaxRange(closingRange) - location
        )
        builder.advanceSource(to: contentRange.location)
        let renderedStart = builder.length
        if parseContents {
            renderInline(contentRange)
        } else {
            builder.appendSource(contentRange)
        }
        let renderedRange = NSRange(
            location: renderedStart,
            length: builder.length - renderedStart
        )
        builder.advanceSource(to: NSMaxRange(fullRange))
        for style in styles {
            builder.addSpan(
                style,
                renderedRange: renderedRange,
                sourceRange: fullRange,
                includesMarkup: true
            )
        }
        parsedTokenEnd = NSMaxRange(fullRange)
        return true
    }

    private func linkToken(
        at location: Int,
        end: Int,
        isImage: Bool
    ) -> LinkToken? {
        let openingLength = isImage ? 2 : 1
        let expectedPrefix = isImage ? "![" : "["
        guard location + openingLength < end,
            source.substring(
                with: NSRange(location: location, length: openingLength)
            ) == expectedPrefix
        else {
            return nil
        }

        let labelStart = location + openingLength
        var scanLocation = labelStart
        var nestedBracketDepth = 0
        var labelTerminator = NSRange(location: NSNotFound, length: 0)
        while scanLocation + 1 < end {
            let character = source.character(at: scanLocation)
            if character == 0x5C {
                scanLocation += min(2, end - scanLocation)
                continue
            }
            if character == 0x5B {
                nestedBracketDepth += 1
            } else if character == 0x5D {
                if nestedBracketDepth > 0 {
                    nestedBracketDepth -= 1
                } else if source.character(at: scanLocation + 1) == 0x28 {
                    labelTerminator = NSRange(
                        location: scanLocation,
                        length: 2
                    )
                    break
                }
            }
            scanLocation += 1
        }
        guard labelTerminator.location != NSNotFound else {
            return nil
        }

        let destinationStart = NSMaxRange(labelTerminator)
        if destinationStart < end,
            source.character(at: destinationStart) == 0x3C
        {
            var scanLocation = destinationStart + 1
            var escaped = false
            while scanLocation < end {
                let character = source.character(at: scanLocation)
                if character == 0x3E, !escaped,
                    scanLocation + 1 < end,
                    source.character(at: scanLocation + 1) == 0x29
                {
                    return LinkToken(
                        fullRange: NSRange(
                            location: location,
                            length: scanLocation + 2 - location
                        ),
                        labelRange: NSRange(
                            location: labelStart,
                            length: labelTerminator.location - labelStart
                        ),
                        destinationRange: NSRange(
                            location: destinationStart + 1,
                            length: scanLocation - destinationStart - 1
                        )
                    )
                }
                escaped = character == 0x5C && !escaped
                if character != 0x5C {
                    escaped = false
                }
                scanLocation += 1
            }
            return nil
        }

        var destinationEnd = destinationStart
        var escaped = false
        var parenthesisDepth = 0
        while destinationEnd < end {
            let character = source.character(at: destinationEnd)
            if character == 0x29, !escaped {
                if parenthesisDepth == 0 {
                    let fullRange = NSRange(
                        location: location,
                        length: destinationEnd + 1 - location
                    )
                    return LinkToken(
                        fullRange: fullRange,
                        labelRange: NSRange(
                            location: labelStart,
                            length: labelTerminator.location - labelStart
                        ),
                        destinationRange: NSRange(
                            location: destinationStart,
                            length: destinationEnd - destinationStart
                        )
                    )
                }
                parenthesisDepth -= 1
            } else if character == 0x28, !escaped {
                parenthesisDepth += 1
            }
            escaped = character == 0x5C && !escaped
            if character != 0x5C {
                escaped = false
            }
            destinationEnd += 1
        }
        return nil
    }

    private func match(
        _ expression: NSRegularExpression,
        in range: NSRange
    ) -> [NSRange]? {
        let substring = source.substring(with: range)
        let localRange = NSRange(
            location: 0,
            length: (substring as NSString).length
        )
        guard let result = expression.firstMatch(
            in: substring,
            range: localRange
        ) else {
            return nil
        }

        return (0..<result.numberOfRanges).map { index in
            let local = result.range(at: index)
            guard local.location != NSNotFound else {
                return local
            }
            return NSRange(
                location: range.location + local.location,
                length: local.length
            )
        }
    }

    private static func expression(
        _ pattern: String
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure(
                "Invalid internal Markdown regular expression: \(pattern)"
            )
        }
    }

    private func openingFence(
        in line: String
    ) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
            return nil
        }
        let markerCharacter = trimmed.first!
        let marker = String(
            trimmed.prefix { $0 == markerCharacter }
        )
        guard marker.count >= 3 else {
            return nil
        }
        let language = trimmed.dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)
        if markerCharacter == "`", language.contains("`") {
            return nil
        }
        return (marker, language.isEmpty ? nil : language)
    }

    private func isClosingFence(_ line: String, for fence: CodeFence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerCharacter = fence.marker.first,
            trimmed.first == markerCharacter
        else {
            return false
        }
        let markerLength = trimmed.prefix { $0 == markerCharacter }.count
        guard markerLength >= fence.marker.count else {
            return false
        }
        return trimmed.dropFirst(markerLength)
            .trimmingCharacters(in: .whitespaces)
            .isEmpty
    }

    private func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first,
            first == "-" || first == "*" || first == "_"
        else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private func isPotentialInlineMarker(_ character: unichar) -> Bool {
        switch character {
        case 0x21, 0x2A, 0x3C, 0x5B, 0x5C, 0x5F, 0x60, 0x7E:
            true
        default:
            false
        }
    }

    private func usesEmphasisBoundaries(_ delimiter: String) -> Bool {
        delimiter.hasPrefix("*")
            || delimiter.hasPrefix("_")
            || delimiter.hasPrefix("~")
    }

    private func isWhitespace(at location: Int) -> Bool {
        character(at: location)?.isWhitespace == true
    }

    private func isWordCharacter(at location: Int) -> Bool {
        guard let character = character(at: location) else {
            return false
        }
        return character.isLetter || character.isNumber
    }

    private func character(at location: Int) -> Character? {
        guard location >= 0, location < source.length else {
            return nil
        }
        let range = source.rangeOfComposedCharacterSequence(at: location)
        return source.substring(with: range).first
    }

    private func isEscaped(_ location: Int) -> Bool {
        var slashCount = 0
        var cursor = location - 1
        while cursor >= 0, source.character(at: cursor) == 0x5C {
            slashCount += 1
            cursor -= 1
        }
        return slashCount % 2 == 1
    }

    private func isMarkdownEscapable(_ character: unichar) -> Bool {
        (character >= 0x21 && character <= 0x2F)
            || (character >= 0x3A && character <= 0x40)
            || (character >= 0x5B && character <= 0x60)
            || (character >= 0x7B && character <= 0x7E)
    }

    private func isMaximalDelimiterRun(
        _ range: NSRange,
        delimiter: String
    ) -> Bool {
        let marker = delimiter as NSString
        guard marker.length > 0 else {
            return true
        }
        let character = marker.character(at: 0)
        guard (1..<marker.length).allSatisfy({
            marker.character(at: $0) == character
        }) else {
            return true
        }
        let previousMatches = range.location > 0
            && source.character(at: range.location - 1) == character
            && !isEscaped(range.location - 1)
        let nextMatches = NSMaxRange(range) < source.length
            && source.character(at: NSMaxRange(range)) == character
        return !previousMatches && !nextMatches
    }
}

private final class RenderBuilder {
    private let source: NSString
    private let rendered = NSMutableString()
    private(set) var spans: [MarkdownRenderSpan] = []
    private var lowerSourceOffsets: [Int] = [0]
    private var upperSourceOffsets: [Int] = [0]

    init(source: NSString) {
        self.source = source
    }

    var length: Int {
        rendered.length
    }

    func appendSource(_ range: NSRange) {
        guard range.length > 0 else {
            advanceSource(to: range.location)
            return
        }
        advanceSource(to: range.location)
        rendered.append(source.substring(with: range))
        for offset in 1...range.length {
            lowerSourceOffsets.append(range.location + offset)
            upperSourceOffsets.append(range.location + offset)
        }
    }

    @discardableResult
    func appendSynthetic(
        _ string: String,
        sourceRange: NSRange
    ) -> NSRange {
        advanceSource(to: sourceRange.location)
        let renderedRange = NSRange(
            location: rendered.length,
            length: (string as NSString).length
        )
        rendered.append(string)
        if renderedRange.length > 0 {
            for offset in 1...renderedRange.length {
                let progress = Double(offset) / Double(renderedRange.length)
                let sourceOffset = sourceRange.location
                    + Int((Double(sourceRange.length) * progress).rounded())
                lowerSourceOffsets.append(sourceOffset)
                upperSourceOffsets.append(sourceOffset)
            }
        }
        return renderedRange
    }

    func advanceSource(to offset: Int) {
        upperSourceOffsets[upperSourceOffsets.count - 1] = offset
    }

    func addSpan(
        _ style: MarkdownRenderStyle,
        renderedRange: NSRange,
        sourceRange: NSRange,
        includesMarkup: Bool = false,
        isAtomic: Bool = false
    ) {
        guard renderedRange.location != NSNotFound else {
            return
        }
        spans.append(
            MarkdownRenderSpan(
                style: style,
                renderedRange: renderedRange,
                sourceRange: sourceRange,
                includesMarkup: includesMarkup,
                isAtomic: isAtomic
            )
        )
    }

    func model() -> MarkdownRenderModel {
        precondition(lowerSourceOffsets.count == rendered.length + 1)
        precondition(upperSourceOffsets.count == rendered.length + 1)
        return MarkdownRenderModel(
            text: rendered as String,
            spans: spans,
            lowerSourceOffsets: lowerSourceOffsets,
            upperSourceOffsets: upperSourceOffsets
        )
    }
}

private struct CodeFence {
    let marker: String
    let language: String?
    let sourceStart: Int
    let renderedStart: Int
}

private struct LinkToken {
    let fullRange: NSRange
    let labelRange: NSRange
    let destinationRange: NSRange
}
