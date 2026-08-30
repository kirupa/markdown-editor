import Foundation

public struct MarkdownEditResult: Equatable {
    public let text: String
    public let selection: NSRange

    public init(text: String, selection: NSRange) {
        self.text = text
        self.selection = selection
    }
}

public enum MarkdownInlineStyle: CaseIterable {
    case bold
    case italic
    case underline
    case strikethrough
    case inlineCode

    fileprivate var markers: (opening: String, closing: String) {
        switch self {
        case .bold:
            ("**", "**")
        case .italic:
            ("*", "*")
        case .underline:
            ("<u>", "</u>")
        case .strikethrough:
            ("~~", "~~")
        case .inlineCode:
            ("`", "`")
        }
    }
}

public enum MarkdownListStyle {
    case bulleted
    case numbered
    case task
}

public enum MarkdownFormatting {
    public static func toggleInline(
        _ style: MarkdownInlineStyle,
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let selectedContent = source.substring(with: selection)
        let markers = markers(for: style, content: selectedContent)
        let openingLength = (markers.opening as NSString).length
        let closingLength = (markers.closing as NSString).length

        if selection.length == 0 {
            let placeholder = placeholderText(for: style)
            let replacement = markers.opening
                + placeholder
                + markers.closing
            return replacing(
                text,
                range: selection,
                with: replacement,
                selection: NSRange(
                    location: selection.location + openingLength,
                    length: (placeholder as NSString).length
                )
            )
        }

        if let combinedResult = removingStyleFromCombinedRun(
            style,
            text: selectedContent
        ) {
            return replacing(
                text,
                range: selection,
                with: combinedResult.text,
                selection: NSRange(
                    location: selection.location
                        + combinedResult.contentOffset,
                    length: combinedResult.contentLength
                )
            )
        }

        if let alternateContent = unwrappedEquivalentStyle(
            style,
            text: selectedContent
        ) {
            return replacing(
                text,
                range: selection,
                with: alternateContent,
                selection: NSRange(
                    location: selection.location,
                    length: (alternateContent as NSString).length
                )
            )
        }

        if let combinedResult = removingStyleFromSurroundingCombinedRun(
            style,
            source: source,
            selection: selection
        ) {
            return combinedResult
        }

        if style == .inlineCode,
            let codeResult = unwrappingSurroundingPaddedCodeSpan(
                source: source,
                selection: selection
            )
        {
            return codeResult
        }

        if style == .inlineCode,
            let unwrapped = unwrappedCodeSpan(selectedContent)
        {
            return replacing(
                text,
                range: selection,
                with: unwrapped,
                selection: NSRange(
                    location: selection.location,
                    length: (unwrapped as NSString).length
                )
            )
        }

        if selection.length >= openingLength + closingLength {
            let selectedText = source.substring(with: selection) as NSString
            let innerLength = selectedText.length - openingLength - closingLength
            if selectedText.substring(
                with: NSRange(location: 0, length: openingLength)
            ) == markers.opening,
                selectedText.substring(
                    with: NSRange(
                        location: openingLength + innerLength,
                        length: closingLength
                    )
                ) == markers.closing,
                markerIsIsolated(
                    in: selectedText,
                    range: NSRange(location: 0, length: openingLength),
                    marker: markers.opening
                ),
                markerIsIsolated(
                    in: selectedText,
                    range: NSRange(
                        location: openingLength + innerLength,
                        length: closingLength
                    ),
                    marker: markers.closing
                )
            {
                let content = selectedText.substring(
                    with: NSRange(location: openingLength, length: innerLength)
                )
                return replacing(
                    text,
                    range: selection,
                    with: content,
                    selection: NSRange(
                        location: selection.location,
                        length: innerLength
                    )
                )
            }
        }

        let openingRange = NSRange(
            location: selection.location - openingLength,
            length: openingLength
        )
        let closingRange = NSRange(
            location: NSMaxRange(selection),
            length: closingLength
        )
        if openingRange.location >= 0,
            NSMaxRange(closingRange) <= source.length,
            source.substring(with: openingRange) == markers.opening,
            source.substring(with: closingRange) == markers.closing,
            markerIsIsolated(
                in: source,
                range: openingRange,
                marker: markers.opening
            ),
            markerIsIsolated(
                in: source,
                range: closingRange,
                marker: markers.closing
            )
        {
            let mutableText = NSMutableString(string: text)
            mutableText.deleteCharacters(in: closingRange)
            mutableText.deleteCharacters(in: openingRange)
            return MarkdownEditResult(
                text: mutableText as String,
                selection: NSRange(
                    location: selection.location - openingLength,
                    length: selection.length
                )
            )
        }

        if let alternateResult = removingSurroundingEquivalentStyle(
            style,
            source: source,
            selection: selection
        ) {
            return alternateResult
        }

        let boundaryParts = style == .inlineCode
            ? (leading: "", content: selectedContent, trailing: "")
            : splitBoundaryWhitespace(selectedContent)
        guard !boundaryParts.content.isEmpty else {
            return MarkdownEditResult(text: text, selection: selection)
        }
        let contentStartsAndEndsWithWhitespace =
            boundaryParts.content.first?.isWhitespace == true
            && boundaryParts.content.last?.isWhitespace == true
            && !boundaryParts.content.allSatisfy(\.isWhitespace)
        let needsCodePadding = style == .inlineCode
            && (
                boundaryParts.content.hasPrefix("`")
                    || boundaryParts.content.hasSuffix("`")
                    || contentStartsAndEndsWithWhitespace
            )
        let padding = needsCodePadding ? " " : ""
        let replacement = boundaryParts.leading
            + markers.opening
            + padding
            + boundaryParts.content
            + padding
            + markers.closing
            + boundaryParts.trailing
        let leadingLength = (boundaryParts.leading as NSString).length
        return replacing(
            text,
            range: selection,
            with: replacement,
            selection: NSRange(
                location: selection.location
                    + leadingLength
                    + openingLength
                    + (padding as NSString).length,
                length: (boundaryParts.content as NSString).length
            )
        )
    }

    public static func applyHeading(
        level requestedLevel: Int,
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        let level = min(max(requestedLevel, 0), 6)
        let lines = selectedLines(in: text, selection: selection)
        let replacement = level == 0
            ? ""
            : String(repeating: "#", count: level) + " "
        let edits = lines.map { line in
            let marker = headingMarker(in: line.content)
            return SourceEdit(
                range: NSRange(
                    location: line.contentRange.location + marker.location,
                    length: marker.length
                ),
                replacement: replacement
            )
        }
        return applying(edits, to: text, selection: selection)
    }

    public static func toggleList(
        _ style: MarkdownListStyle,
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        let lines = selectedLines(in: text, selection: selection)
        let nonemptyLines = lines.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let shouldRemove = !nonemptyLines.isEmpty && nonemptyLines.allSatisfy {
            listMarker(in: $0.content)?.style == style
        }

        var itemNumber = 1
        let edits = lines.compactMap { line -> SourceEdit? in
            let content = line.content
            if content.trimmingCharacters(in: .whitespaces).isEmpty,
                lines.count > 1
            {
                return nil
            }

            let indentationLength = indentationLength(in: content)
            let existingMarker = listMarker(in: content)
            let oldMarkerRange = existingMarker?.range
                ?? NSRange(location: indentationLength, length: 0)

            let replacement: String
            if shouldRemove {
                guard existingMarker?.style == style else {
                    return nil
                }
                replacement = ""
            } else {
                switch style {
                case .bulleted:
                    replacement = "- "
                case .numbered:
                    replacement = "\(itemNumber). "
                    itemNumber += 1
                case .task:
                    replacement = "- [ ] "
                }
            }

            return SourceEdit(
                range: NSRange(
                    location: line.contentRange.location
                        + oldMarkerRange.location,
                    length: oldMarkerRange.length
                ),
                replacement: replacement
            )
        }

        return applying(edits, to: text, selection: selection)
    }

    public static func toggleQuote(
        in text: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        let lines = selectedLines(in: text, selection: selection)
        let nonemptyLines = lines.filter {
            !$0.content.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let shouldRemove = !nonemptyLines.isEmpty && nonemptyLines.allSatisfy {
            quoteMarker(in: $0.content).length > 0
        }

        let edits = lines.compactMap { line -> SourceEdit? in
            if line.content.trimmingCharacters(in: .whitespaces).isEmpty,
                lines.count > 1
            {
                return nil
            }

            let marker = quoteMarker(in: line.content)
            let indentation = indentationLength(in: line.content)
            return SourceEdit(
                range: NSRange(
                    location: line.contentRange.location
                        + (marker.length > 0 ? marker.location : indentation),
                    length: marker.length
                ),
                replacement: shouldRemove ? "" : (marker.length > 0 ? "> " : "> ")
            )
        }

        return applying(edits, to: text, selection: selection)
    }

    public static func wrapCodeBlock(
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)

        if selection.length == 0 {
            let needsLeadingNewline = selection.location > 0
                && source.substring(
                    with: NSRange(
                        location: selection.location - 1,
                        length: 1
                    )
                ) != "\n"
            let needsTrailingNewline = selection.location < source.length
            let leadingNewline = needsLeadingNewline ? "\n" : ""
            let trailingNewline = needsTrailingNewline ? "\n" : ""
            let replacement = leadingNewline
                + "```\n\n```"
                + trailingNewline
            return replacing(
                text,
                range: selection,
                with: replacement,
                selection: NSRange(
                    location: selection.location
                        + (leadingNewline as NSString).length
                        + 4,
                    length: 0
                )
            )
        }

        let lineProbe = NSRange(
            location: selection.location,
            length: max(0, selection.length - 1)
        )
        let blockRange = source.lineRange(for: lineProbe)
        let selectedText = source.substring(with: blockRange)
        let fence = codeFence(for: selectedText)
        let endsWithNewline = selectedText.hasSuffix("\n")
        let replacement = endsWithNewline
            ? "\(fence)\n\(selectedText)\(fence)\n"
            : "\(fence)\n\(selectedText)\n\(fence)"
        return replacing(
            text,
            range: blockRange,
            with: replacement,
            selection: NSRange(
                location: selection.location
                    + (fence as NSString).length
                    + 1,
                length: selection.length
            )
        )
    }

    public static func insertNewline(
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        guard selection.length == 0 else {
            return replacing(
                text,
                range: selection,
                with: "\n",
                selection: NSRange(
                    location: selection.location + 1,
                    length: 0
                )
            )
        }

        var lineStart = 0
        var contentsEnd = 0
        source.getLineStart(
            &lineStart,
            end: nil,
            contentsEnd: &contentsEnd,
            for: NSRange(location: selection.location, length: 0)
        )
        let contentRange = NSRange(
            location: lineStart,
            length: contentsEnd - lineStart
        )
        let line = source.substring(with: contentRange)
        guard let continuation = continuationInfo(in: line),
            selection.location
                >= contentRange.location + continuation.markerRange.length
        else {
            return replacing(
                text,
                range: selection,
                with: "\n",
                selection: NSRange(
                    location: selection.location + 1,
                    length: 0
                )
            )
        }

        let contentAfterMarker = (line as NSString).substring(
            from: continuation.markerRange.length
        )
        if contentAfterMarker.trimmingCharacters(in: .whitespaces).isEmpty {
            let markerRange = NSRange(
                location: contentRange.location,
                length: continuation.markerRange.length
            )
            return replacing(
                text,
                range: markerRange,
                with: "",
                selection: NSRange(
                    location: contentRange.location,
                    length: 0
                )
            )
        }

        let replacement = "\n\(continuation.nextPrefix)"
        return replacing(
            text,
            range: selection,
            with: replacement,
            selection: NSRange(
                location: selection.location
                    + (replacement as NSString).length,
                length: 0
            )
        )
    }

    public static func insertLink(
        destination: String,
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let label = selection.length > 0
            ? source.substring(with: selection)
            : "link text"
        let escapedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let encodedDestination = destination
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
        let replacement = "[\(escapedLabel)](\(encodedDestination))"
        return replacing(
            text,
            range: selection,
            with: replacement,
            selection: NSRange(
                location: selection.location + 1,
                length: (escapedLabel as NSString).length
            )
        )
    }

    /// Insert an image reference at the caret.
    ///
    /// Used by both routes into a document — a file copied into the assets
    /// folder and a URL typed by hand — so the two produce identical text.
    public static func insertImage(
        destination: String,
        altText: String = "",
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let selected = selection.length > 0
            ? source.substring(with: selection)
            : ""
        let label = !altText.isEmpty
            ? altText
            : (!selected.isEmpty ? selected : "image")
        let replacement = MarkdownImageTag.reference(
            destination: destination,
            altText: label
        )
        let escapedLabel = MarkdownImageTag.escapeLabel(label) as NSString
        return replacing(
            text,
            range: selection,
            with: replacement,
            // Select the alt text so it can be typed straight over.
            selection: NSRange(
                location: selection.location + 2,
                length: escapedLabel.length
            )
        )
    }

    /// Set or clear the pixel size of the image written at `range`.
    ///
    /// A sized image cannot be Markdown — there is no syntax for it — so this
    /// converts between the two forms in both directions: adding a size
    /// rewrites `![alt](src)` as `<img …>`, and clearing it turns the tag back
    /// into Markdown. Anything that is not exactly one image reference is left
    /// untouched, so a stale range from a document that has since been edited
    /// can never corrupt it.
    public static func setImageSize(
        in text: String,
        range requestedRange: NSRange,
        size: MarkdownImageTag.Size
    ) -> MarkdownEditResult {
        let source = text as NSString
        let range = clamped(requestedRange, to: source.length)
        guard let image = readImage(source, range: range) else {
            return MarkdownEditResult(text: text, selection: range)
        }

        let replacement = MarkdownImageTag.reference(
            destination: image.destination,
            altText: image.altText,
            size: size
        )
        return replacing(
            text,
            range: range,
            with: replacement,
            // Keep the image selected: the size fields are driven by the
            // selection, so dropping it on every keystroke would make them
            // unusable.
            selection: NSRange(
                location: range.location,
                length: (replacement as NSString).length
            )
        )
    }

    /// Move the image occupying `range` so that it becomes its own block at
    /// `destination`.
    ///
    /// `destination` is an offset into the *original* text and is snapped to a
    /// line boundary, because a picture dropped between two lines belongs
    /// between them rather than inside one. Splicing it at an arbitrary
    /// character is what the first version did, and it produced documents like
    /// `Ome![photo](a.png)ga paragraph.` from a drop aimed at the gap above.
    ///
    /// The picture takes its line with it when the line held nothing else, so
    /// moving a picture does not leave an empty paragraph behind and does not
    /// add a paragraph break every time it is moved.
    public static func moveImage(
        in text: String,
        range requestedRange: NSRange,
        to destination: Int
    ) -> MarkdownEditResult {
        let source = text as NSString
        let range = clamped(requestedRange, to: source.length)
        let target = min(max(destination, 0), source.length)

        guard range.length > 0, readImage(source, range: range) != nil else {
            return MarkdownEditResult(text: text, selection: range)
        }
        // Anywhere from the first character to the last is the image's own
        // text; landing there means it did not go anywhere.
        guard target < range.location || target > NSMaxRange(range) else {
            return MarkdownEditResult(text: text, selection: range)
        }

        let markdown = source.substring(with: range)
        let removal = imageBlockRange(source, imageRange: range)
        let mutable = NSMutableString(string: text)
        mutable.deleteCharacters(in: removal)

        // The destination was measured against the document as it stood, so
        // every offset after the removal has shifted left by what was taken.
        var moved = shifting(target, removing: removal)
        if let collapsed = collapseNewlineRun(mutable, at: removal.location) {
            moved = shifting(moved, removing: collapsed)
        }

        let insertion = lineBoundary(mutable, near: moved)
        let (before, after) = blockSeparators(mutable, at: insertion)
        mutable.insert(before + markdown + after, at: insertion)

        return MarkdownEditResult(
            text: mutable as String,
            // Keep the picture selected where it landed, so it can be nudged
            // again or resized without hunting for it.
            selection: NSRange(
                location: insertion + (before as NSString).length,
                length: (markdown as NSString).length
            )
        )
    }

    /// What to remove when lifting a picture out.
    ///
    /// A picture alone on its line takes the line with it. A picture sitting in
    /// the middle of a sentence takes only itself, because removing that line
    /// would take the sentence too.
    private static func imageBlockRange(
        _ source: NSString,
        imageRange: NSRange
    ) -> NSRange {
        let line = source.lineRange(for: imageRange)
        let leading = source.substring(
            with: NSRange(
                location: line.location,
                length: imageRange.location - line.location
            )
        )
        let trailingStart = NSMaxRange(imageRange)
        let trailing = source.substring(
            with: NSRange(
                location: trailingStart,
                length: NSMaxRange(line) - trailingStart
            )
        )
        guard
            leading.trimmingCharacters(in: .whitespaces).isEmpty,
            trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return imageRange }
        return line
    }

    /// Where `offset` ends up once `removed` has been taken out.
    private static func shifting(_ offset: Int, removing removed: NSRange) -> Int {
        if offset <= removed.location { return offset }
        if offset >= NSMaxRange(removed) { return offset - removed.length }
        return removed.location
    }

    /// Reduce a run of blank lines at `offset` to a single blank line.
    ///
    /// Taking a picture's line out leaves the blank line above it next to the
    /// blank line below it, which reads as a paragraph break the author never
    /// typed.
    @discardableResult
    private static func collapseNewlineRun(
        _ text: NSMutableString,
        at offset: Int
    ) -> NSRange? {
        guard offset >= 0, offset <= text.length else { return nil }
        var start = offset
        while start > 0, text.character(at: start - 1) == 0x0A { start -= 1 }
        var end = offset
        while end < text.length, text.character(at: end) == 0x0A { end += 1 }
        // A blank line is two newlines in the body of a document, but at the
        // very end it is trailing whitespace, and at the very start it is a
        // leading empty line. Taking a picture's block out should not leave
        // either behind.
        let keep: Int
        if start == 0 {
            keep = 0
        } else if end >= text.length {
            keep = 1
        } else {
            keep = 2
        }
        guard end - start > keep else { return nil }
        let excess = NSRange(location: start + keep, length: end - start - keep)
        text.deleteCharacters(in: excess)
        return excess
    }

    /// The start of the line `offset` falls in, so an insertion lands between
    /// lines rather than inside one.
    private static func lineBoundary(_ text: NSString, near offset: Int) -> Int {
        guard offset < text.length else { return text.length }
        return text.lineRange(for: NSRange(location: offset, length: 0)).location
    }

    /// The newlines needed either side of `offset` for what is inserted there
    /// to be a block of its own.
    private static func blockSeparators(
        _ text: NSString,
        at offset: Int
    ) -> (String, String) {
        let before: String
        if offset <= 0 {
            before = ""
        } else {
            let prefix = text.substring(to: offset)
            before = prefix.hasSuffix("\n\n") ? "" : (prefix.hasSuffix("\n") ? "\n" : "\n\n")
        }
        let after: String
        if offset >= text.length {
            after = ""
        } else {
            let suffix = text.substring(from: offset)
            after = suffix.hasPrefix("\n\n") ? "" : (suffix.hasPrefix("\n") ? "\n" : "\n\n")
        }
        return (before, after)
    }

    /// The image reference occupying exactly `range`, in either form, or nil.
    public static func readImage(
        _ source: NSString,
        range: NSRange
    ) -> MarkdownImageTag.Parsed? {
        guard range.length > 0 else { return nil }
        if source.character(at: range.location) == 0x3C {          // <
            guard
                let tag = MarkdownImageTag.parse(
                    source,
                    at: range.location,
                    end: NSMaxRange(range)
                ),
                tag.end == NSMaxRange(range)
            else { return nil }
            return tag
        }
        return markdownImage(source, range: range)
    }

    /// `![alt](destination)` occupying exactly `range`.
    private static func markdownImage(
        _ source: NSString,
        range: NSRange
    ) -> MarkdownImageTag.Parsed? {
        let end = NSMaxRange(range)
        var scan = range.location
        guard
            scan + 1 < end,
            source.character(at: scan) == 0x21,                    // !
            source.character(at: scan + 1) == 0x5B                 // [
        else { return nil }
        scan += 2

        var label = ""
        while scan < end {
            let character = source.character(at: scan)
            if character == 0x5C, scan + 1 < end {                 // backslash
                label.append(
                    Character(
                        Unicode.Scalar(source.character(at: scan + 1))
                            ?? Unicode.Scalar(0x20)!
                    )
                )
                scan += 2
                continue
            }
            if character == 0x5D { break }                          // ]
            if character == 0x5B { return nil }                    // [
            label.append(
                Character(Unicode.Scalar(character) ?? Unicode.Scalar(0x20)!)
            )
            scan += 1
        }
        guard
            scan < end,
            source.character(at: scan) == 0x5D,                    // ]
            scan + 1 < end,
            source.character(at: scan + 1) == 0x28                 // (
        else { return nil }

        let destinationStart = scan + 2
        var destinationEnd = destinationStart
        while destinationEnd < end {
            let character = source.character(at: destinationEnd)
            if character == 0x29 { break }                          // )
            if character == 0x28 { return nil }                    // (
            if character == 0x20 || character == 0x0A { return nil }
            destinationEnd += 1
        }
        guard
            destinationEnd < end,
            source.character(at: destinationEnd) == 0x29,
            destinationEnd + 1 == end
        else { return nil }

        return MarkdownImageTag.Parsed(
            end: end,
            destination: source.substring(
                with: NSRange(
                    location: destinationStart,
                    length: destinationEnd - destinationStart
                )
            ),
            altText: label,
            width: nil,
            height: nil
        )
    }

    public static func insertHorizontalRule(
        in text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let needsLeadingNewline = selection.location > 0
            && source.substring(
                with: NSRange(location: selection.location - 1, length: 1)
            ) != "\n"
        let needsTrailingNewline = NSMaxRange(selection) < source.length
            && source.substring(
                with: NSRange(location: NSMaxRange(selection), length: 1)
            ) != "\n"
        let replacement = (needsLeadingNewline ? "\n" : "")
            + "***\n"
            + (needsTrailingNewline ? "\n" : "")
        return replacing(
            text,
            range: selection,
            with: replacement,
            selection: NSRange(
                location: selection.location + (replacement as NSString).length,
                length: 0
            )
        )
    }

    private static func replacing(
        _ text: String,
        range: NSRange,
        with replacement: String,
        selection: NSRange
    ) -> MarkdownEditResult {
        let mutableText = NSMutableString(string: text)
        mutableText.replaceCharacters(in: range, with: replacement)
        return MarkdownEditResult(
            text: mutableText as String,
            selection: selection
        )
    }

    private static func applying(
        _ edits: [SourceEdit],
        to text: String,
        selection requestedSelection: NSRange
    ) -> MarkdownEditResult {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let sortedEdits = edits.sorted {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }
        let mutableText = NSMutableString(string: text)

        for edit in sortedEdits.reversed() {
            mutableText.replaceCharacters(
                in: edit.range,
                with: edit.replacement
            )
        }

        var start = selection.location
        var end = NSMaxRange(selection)
        var accumulatedDelta = 0
        for edit in sortedEdits {
            let adjustedRange = NSRange(
                location: edit.range.location + accumulatedDelta,
                length: edit.range.length
            )
            let replacementLength = (edit.replacement as NSString).length
            start = mapped(
                start,
                through: adjustedRange,
                replacementLength: replacementLength
            )
            end = mapped(
                end,
                through: adjustedRange,
                replacementLength: replacementLength
            )
            accumulatedDelta += replacementLength - edit.range.length
        }

        return MarkdownEditResult(
            text: mutableText as String,
            selection: NSRange(
                location: start,
                length: max(0, end - start)
            )
        )
    }

    private static func mapped(
        _ position: Int,
        through editRange: NSRange,
        replacementLength: Int
    ) -> Int {
        if position < editRange.location {
            return position
        }

        if editRange.length == 0 {
            return position + replacementLength
        }

        if position >= NSMaxRange(editRange) {
            return position + replacementLength - editRange.length
        }

        return editRange.location + replacementLength
    }

    private static func selectedLines(
        in text: String,
        selection requestedSelection: NSRange
    ) -> [SourceLine] {
        let source = text as NSString
        let selection = clamped(requestedSelection, to: source.length)
        let lineProbe: NSRange
        if selection.length > 0 {
            lineProbe = NSRange(
                location: selection.location,
                length: max(0, selection.length - 1)
            )
        } else {
            lineProbe = selection
        }
        let selectedLineRange = source.lineRange(for: lineProbe)

        if source.length == 0 {
            return [
                SourceLine(
                    content: "",
                    contentRange: NSRange(location: 0, length: 0)
                )
            ]
        }

        var lines: [SourceLine] = []
        var location = selectedLineRange.location
        let rangeEnd = NSMaxRange(selectedLineRange)
        if selectedLineRange.length == 0 {
            return [
                SourceLine(
                    content: "",
                    contentRange: NSRange(
                        location: selectedLineRange.location,
                        length: 0
                    )
                )
            ]
        }
        while location < rangeEnd {
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
            lines.append(
                SourceLine(
                    content: source.substring(with: contentRange),
                    contentRange: contentRange
                )
            )
            location = max(lineEnd, location + 1)
        }
        return lines
    }

    private static func headingMarker(in line: String) -> NSRange {
        firstMatch(
            pattern: #"^([ \t]*)(#{1,6}[ \t]+)"#,
            in: line,
            captureGroup: 2
        ) ?? NSRange(
            location: indentationLength(in: line),
            length: 0
        )
    }

    private static func quoteMarker(in line: String) -> NSRange {
        firstMatch(
            pattern: #"^([ \t]*)(>[ \t]?)"#,
            in: line,
            captureGroup: 2
        ) ?? NSRange(
            location: indentationLength(in: line),
            length: 0
        )
    }

    private static func listMarker(
        in line: String
    ) -> (range: NSRange, style: MarkdownListStyle)? {
        let patterns: [(String, MarkdownListStyle)] = [
            (#"^([ \t]*)([-+*][ \t]+\[[ xX]\][ \t]+)"#, .task),
            (#"^([ \t]*)(\d+[.)][ \t]+)"#, .numbered),
            (#"^([ \t]*)([-+*][ \t]+)"#, .bulleted)
        ]

        for (pattern, style) in patterns {
            if let range = firstMatch(
                pattern: pattern,
                in: line,
                captureGroup: 2
            ) {
                return (range, style)
            }
        }
        return nil
    }

    private static func firstMatch(
        pattern: String,
        in string: String,
        captureGroup: Int
    ) -> NSRange? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            preconditionFailure("Invalid internal Markdown regular expression")
        }
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        guard let match = expression.firstMatch(
            in: string,
            range: fullRange
        ) else {
            return nil
        }
        return match.range(at: captureGroup)
    }

    private static func indentationLength(in line: String) -> Int {
        let source = line as NSString
        var length = 0
        while length < source.length {
            let character = source.character(at: length)
            guard character == 0x20 || character == 0x09 else {
                break
            }
            length += 1
        }
        return length
    }

    private static func continuationInfo(
        in line: String
    ) -> (markerRange: NSRange, nextPrefix: String)? {
        let patterns: [
            (
                pattern: String,
                makePrefix: (NSTextCheckingResult, NSString) -> String
            )
        ] = [
            (
                #"^([ \t]*(?:>[ \t]?)*)([-+*][ \t]+\[[ xX]\][ \t]+)"#,
                { match, source in
                    source.substring(with: match.range(at: 1)) + "- [ ] "
                }
            ),
            (
                #"^([ \t]*(?:>[ \t]?)*)([-+*][ \t]+)"#,
                { match, source in
                    source.substring(with: match.range(at: 1)) + "- "
                }
            ),
            (
                #"^([ \t]*(?:>[ \t]?)*)(\d{1,9})([.)])([ \t]+)"#,
                { match, source in
                    let prefix = source.substring(with: match.range(at: 1))
                    let number = Int(
                        source.substring(with: match.range(at: 2))
                    ) ?? 0
                    let delimiter = source.substring(
                        with: match.range(at: 3)
                    )
                    let spacing = source.substring(with: match.range(at: 4))
                    let nextNumber = number < 999_999_999
                        ? number + 1
                        : number
                    return "\(prefix)\(nextNumber)\(delimiter)\(spacing)"
                }
            ),
            (
                #"^([ \t]*(?:>[ \t]?)+)"#,
                { match, source in
                    source.substring(with: match.range(at: 1))
                }
            )
        ]
        let source = line as NSString
        let fullRange = NSRange(location: 0, length: source.length)

        for item in patterns {
            guard let expression = try? NSRegularExpression(
                pattern: item.pattern
            ) else {
                preconditionFailure(
                    "Invalid internal Markdown continuation expression"
                )
            }
            if let match = expression.firstMatch(
                in: line,
                range: fullRange
            ) {
                return (
                    match.range(at: 0),
                    item.makePrefix(match, source)
                )
            }
        }
        return nil
    }

    private static func markers(
        for style: MarkdownInlineStyle,
        content: String
    ) -> (opening: String, closing: String) {
        guard style == .inlineCode else {
            return style.markers
        }

        let source = content as NSString
        var longestRun = 0
        var currentRun = 0
        for location in 0..<source.length {
            if source.character(at: location) == 0x60 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let delimiter = String(
            repeating: "`",
            count: max(1, longestRun + 1)
        )
        return (delimiter, delimiter)
    }

    private static func codeFence(for content: String) -> String {
        let source = content as NSString
        var longestRun = 0
        var currentRun = 0
        for location in 0..<source.length {
            if source.character(at: location) == 0x60 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(
            repeating: "`",
            count: max(3, longestRun + 1)
        )
    }

    private static func unwrappedCodeSpan(_ text: String) -> String? {
        let source = text as NSString
        var openingLength = 0
        while openingLength < source.length,
            source.character(at: openingLength) == 0x60
        {
            openingLength += 1
        }
        guard openingLength > 0,
            source.length > openingLength * 2
        else {
            return nil
        }
        let closingRange = NSRange(
            location: source.length - openingLength,
            length: openingLength
        )
        guard source.substring(with: closingRange)
            == String(repeating: "`", count: openingLength)
        else {
            return nil
        }
        var content = source.substring(
            with: NSRange(
                location: openingLength,
                length: source.length - openingLength * 2
            )
        )
        let contentSource = content as NSString
        if contentSource.length >= 2,
            contentSource.character(at: 0) == 0x20,
            contentSource.character(at: contentSource.length - 1) == 0x20,
            !content.allSatisfy(\.isWhitespace)
        {
            content = contentSource.substring(
                with: NSRange(
                    location: 1,
                    length: contentSource.length - 2
                )
            )
        }
        return content
    }

    private static func removingStyleFromCombinedRun(
        _ style: MarkdownInlineStyle,
        text: String
    ) -> (text: String, contentOffset: Int, contentLength: Int)? {
        guard style == .bold || style == .italic else {
            return nil
        }
        let source = text as NSString
        guard source.length > 0 else {
            return nil
        }
        let markerCharacter = source.character(at: 0)
        guard markerCharacter == 0x2A || markerCharacter == 0x5F else {
            return nil
        }
        var openingRun = 0
        while openingRun < source.length,
            source.character(at: openingRun) == markerCharacter
        {
            openingRun += 1
        }
        var closingRun = 0
        while closingRun < source.length,
            source.character(at: source.length - closingRun - 1)
                == markerCharacter
        {
            closingRun += 1
        }
        guard openingRun == 3, closingRun == 3,
            source.length > openingRun + closingRun
        else {
            return nil
        }

        let markersToRemove = style == .bold ? 2 : 1
        let remainingMarkers = 3 - markersToRemove
        let content = source.substring(
            with: NSRange(
                location: openingRun,
                length: source.length - openingRun - closingRun
            )
        )
        let marker = String(
            repeating: markerCharacter == 0x2A ? "*" : "_",
            count: remainingMarkers
        )
        return (
            marker + content + marker,
            remainingMarkers,
            (content as NSString).length
        )
    }

    private static func unwrappedEquivalentStyle(
        _ style: MarkdownInlineStyle,
        text: String
    ) -> String? {
        let source = text as NSString
        for markers in alternateMarkers(for: style) {
            let openingLength = (markers.opening as NSString).length
            let closingLength = (markers.closing as NSString).length
            guard source.length > openingLength + closingLength else {
                continue
            }
            let openingRange = NSRange(
                location: 0,
                length: openingLength
            )
            let closingRange = NSRange(
                location: source.length - closingLength,
                length: closingLength
            )
            if source.substring(with: openingRange) == markers.opening,
                source.substring(with: closingRange) == markers.closing,
                markerIsIsolated(
                    in: source,
                    range: openingRange,
                    marker: markers.opening
                ),
                markerIsIsolated(
                    in: source,
                    range: closingRange,
                    marker: markers.closing
                )
            {
                return source.substring(
                    with: NSRange(
                        location: openingLength,
                        length: source.length
                            - openingLength
                            - closingLength
                    )
                )
            }
        }
        return nil
    }

    private static func removingStyleFromSurroundingCombinedRun(
        _ style: MarkdownInlineStyle,
        source: NSString,
        selection: NSRange
    ) -> MarkdownEditResult? {
        guard style == .bold || style == .italic,
            selection.location >= 3,
            NSMaxRange(selection) + 3 <= source.length
        else {
            return nil
        }
        let markerCharacter = source.character(at: selection.location - 1)
        guard markerCharacter == 0x2A || markerCharacter == 0x5F else {
            return nil
        }
        let openingRange = NSRange(
            location: selection.location - 3,
            length: 3
        )
        let closingRange = NSRange(
            location: NSMaxRange(selection),
            length: 3
        )
        guard (0..<3).allSatisfy({
            source.character(at: openingRange.location + $0)
                == markerCharacter
                && source.character(at: closingRange.location + $0)
                    == markerCharacter
        }) else {
            return nil
        }
        let markersToRemove = style == .bold ? 2 : 1
        let remainingMarkers = 3 - markersToRemove
        let marker = String(
            repeating: markerCharacter == 0x2A ? "*" : "_",
            count: remainingMarkers
        )
        let mutableSource = NSMutableString(string: source)
        mutableSource.replaceCharacters(in: closingRange, with: marker)
        mutableSource.replaceCharacters(in: openingRange, with: marker)
        return MarkdownEditResult(
            text: mutableSource as String,
            selection: NSRange(
                location: selection.location - markersToRemove,
                length: selection.length
            )
        )
    }

    private static func unwrappingSurroundingPaddedCodeSpan(
        source: NSString,
        selection: NSRange
    ) -> MarkdownEditResult? {
        guard selection.location >= 2,
            NSMaxRange(selection) + 2 <= source.length,
            source.character(at: selection.location - 1) == 0x20,
            source.character(at: NSMaxRange(selection)) == 0x20
        else {
            return nil
        }

        var openingStart = selection.location - 1
        while openingStart > 0,
            source.character(at: openingStart - 1) == 0x60
        {
            openingStart -= 1
        }
        var closingEnd = NSMaxRange(selection) + 1
        while closingEnd < source.length,
            source.character(at: closingEnd) == 0x60
        {
            closingEnd += 1
        }
        let openingLength = selection.location - 1 - openingStart
        let closingLength = closingEnd - NSMaxRange(selection) - 1
        guard openingLength > 0, openingLength == closingLength else {
            return nil
        }

        let mutableSource = NSMutableString(string: source)
        mutableSource.deleteCharacters(
            in: NSRange(
                location: NSMaxRange(selection),
                length: 1 + closingLength
            )
        )
        mutableSource.deleteCharacters(
            in: NSRange(
                location: openingStart,
                length: openingLength + 1
            )
        )
        return MarkdownEditResult(
            text: mutableSource as String,
            selection: NSRange(
                location: openingStart,
                length: selection.length
            )
        )
    }

    private static func removingSurroundingEquivalentStyle(
        _ style: MarkdownInlineStyle,
        source: NSString,
        selection: NSRange
    ) -> MarkdownEditResult? {
        for markers in alternateMarkers(for: style) {
            let openingLength = (markers.opening as NSString).length
            let closingLength = (markers.closing as NSString).length
            let openingRange = NSRange(
                location: selection.location - openingLength,
                length: openingLength
            )
            let closingRange = NSRange(
                location: NSMaxRange(selection),
                length: closingLength
            )
            guard openingRange.location >= 0,
                NSMaxRange(closingRange) <= source.length,
                source.substring(with: openingRange) == markers.opening,
                source.substring(with: closingRange) == markers.closing,
                markerIsIsolated(
                    in: source,
                    range: openingRange,
                    marker: markers.opening
                ),
                markerIsIsolated(
                    in: source,
                    range: closingRange,
                    marker: markers.closing
                )
            else {
                continue
            }

            let mutableSource = NSMutableString(string: source)
            mutableSource.deleteCharacters(in: closingRange)
            mutableSource.deleteCharacters(in: openingRange)
            return MarkdownEditResult(
                text: mutableSource as String,
                selection: NSRange(
                    location: selection.location - openingLength,
                    length: selection.length
                )
            )
        }
        return nil
    }

    private static func alternateMarkers(
        for style: MarkdownInlineStyle
    ) -> [(opening: String, closing: String)] {
        switch style {
        case .bold:
            [("__", "__")]
        case .italic:
            [("_", "_")]
        default:
            []
        }
    }

    private static func splitBoundaryWhitespace(
        _ text: String
    ) -> (leading: String, content: String, trailing: String) {
        let leading = String(text.prefix { $0.isWhitespace })
        let withoutLeading = text.dropFirst(leading.count)
        let trailing = String(
            withoutLeading.reversed()
                .prefix { $0.isWhitespace }
                .reversed()
        )
        let content = String(
            withoutLeading.dropLast(trailing.count)
        )
        return (leading, content, trailing)
    }

    private static func placeholderText(
        for style: MarkdownInlineStyle
    ) -> String {
        switch style {
        case .bold:
            "bold text"
        case .italic:
            "italic text"
        case .underline:
            "underlined text"
        case .strikethrough:
            "struck text"
        case .inlineCode:
            "code"
        }
    }

    private static func markerIsIsolated(
        in source: NSString,
        range: NSRange,
        marker: String
    ) -> Bool {
        let markerSource = marker as NSString
        guard markerSource.length > 0 else {
            return true
        }
        let markerCharacter = markerSource.character(at: 0)
        guard (1..<markerSource.length).allSatisfy({
            markerSource.character(at: $0) == markerCharacter
        }) else {
            return true
        }

        let previousMatches = range.location > 0
            && source.character(at: range.location - 1) == markerCharacter
        let nextMatches = NSMaxRange(range) < source.length
            && source.character(at: NSMaxRange(range)) == markerCharacter
        return !previousMatches && !nextMatches
    }

    private static func clamped(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(
            location: location,
            length: min(max(0, range.length), length - location)
        )
    }
}

private struct SourceEdit {
    let range: NSRange
    let replacement: String
}

private struct SourceLine {
    let content: String
    let contentRange: NSRange
}
