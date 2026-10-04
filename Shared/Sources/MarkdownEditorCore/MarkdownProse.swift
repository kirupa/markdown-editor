import Foundation

/// The words a reader would read, with the Markdown taken out.
///
/// Counting whitespace-separated runs of the raw text is wrong in the direction
/// that matters: a new document is `# `, which trims to `#` and passes for
/// content, and a draft that is mostly a code sample or a table of links
/// counts its syntax as writing. A critique of either spends a request to
/// report that there is nothing there — measured as a hundred out of a
/// hundred, "Ready", for a document that was one hash sign.
///
/// So this skips what a reader never reads as prose — fenced code, front
/// matter, link and image destinations, reference definitions, HTML tags and
/// comments, list and heading markers — and counts what is left. A word is a
/// run of non-space characters with at least one letter or digit in it, so a
/// dash between spaces is punctuation rather than a word, and
/// `state-of-the-art` is one. Han, Hiragana and Katakana are written without
/// spaces, so each of those characters counts as a word, which is how word
/// counts are conventionally given for them.
///
/// One linear pass over the text and no regular expressions: the status bar
/// asks for this as the author types, in drafts measured at 23,000 words.
public enum MarkdownProse {
    public static func wordCount(_ markdown: String) -> Int {
        var scanner = WordScanner(Array(markdown.unicodeScalars))
        return scanner.count()
    }

    private struct WordScanner {
        let text: [Unicode.Scalar]
        var words = 0
        var inWord = false
        var wordHasContent = false

        init(_ text: [Unicode.Scalar]) {
            self.text = text
        }

        mutating func count() -> Int {
            var lineStart = skipFrontMatter()
            var fence: (marker: Unicode.Scalar, length: Int)?
            var inComment = false
            while lineStart < text.count {
                var lineEnd = lineStart
                while lineEnd < text.count, text[lineEnd] != "\n" { lineEnd += 1 }
                defer { lineStart = lineEnd + 1 }

                var at = lineStart
                if inComment {
                    guard let close = find("-->", from: at, before: lineEnd) else {
                        continue
                    }
                    inComment = false
                    at = close + 3
                } else {
                    at = skipQuoteMarkers(from: at, before: lineEnd)
                    if let open = fence {
                        if isClosingFence(open, from: at, before: lineEnd) { fence = nil }
                        continue
                    }
                    if let opened = openingFence(from: at, before: lineEnd) {
                        fence = opened
                        continue
                    }
                    guard let content = skipLineMarkers(from: at, before: lineEnd)
                    else { continue }
                    at = content
                }
                inComment = scanInline(from: at, before: lineEnd)
                endWord()
            }
            endWord()
            return words
        }

        // MARK: Blocks

        /// Where the text starts once a YAML block at the very top is set
        /// aside. Only an opening `---` on the first line counts, followed by
        /// a key, and only when it is closed: otherwise it is a thematic
        /// break, and the draft beneath it is prose.
        func skipFrontMatter() -> Int {
            guard let firstEnd = endOfLine(from: 0),
                  isOnly("-", 3, from: 0, before: firstEnd),
                  startsWithKey(at: firstEnd + 1)
            else { return 0 }
            var lineStart = firstEnd + 1
            while lineStart < text.count {
                let lineEnd = endOfLine(from: lineStart) ?? text.count
                if isOnly("-", 3, from: lineStart, before: lineEnd)
                    || isOnly(".", 3, from: lineStart, before: lineEnd) {
                    return lineEnd + 1
                }
                lineStart = lineEnd + 1
            }
            return 0
        }

        /// `title:` or `draft-date:` at the start of a line.
        func startsWithKey(at start: Int) -> Bool {
            var at = start
            while at < text.count,
                  isASCIILetter(text[at]) || isDigit(text[at])
                    || text[at] == "_" || text[at] == "-" {
                at += 1
            }
            return at > start && at < text.count && text[at] == ":"
        }

        func endOfLine(from start: Int) -> Int? {
            var at = start
            while at < text.count {
                if text[at] == "\n" { return at }
                at += 1
            }
            return start < text.count ? text.count : nil
        }

        /// Whether the line is exactly `count` of `marker`, give or take
        /// trailing spaces.
        func isOnly(_ marker: Unicode.Scalar, _ count: Int, from start: Int, before end: Int) -> Bool {
            var at = start
            var seen = 0
            while at < end, text[at] == marker { seen += 1; at += 1 }
            guard seen == count else { return false }
            while at < end, isSpace(text[at]) { at += 1 }
            return at == end
        }

        func skipQuoteMarkers(from start: Int, before end: Int) -> Int {
            var at = skipSpaces(from: start, before: end)
            while at < end, text[at] == ">" {
                at = skipSpaces(from: at + 1, before: end)
            }
            return at
        }

        func openingFence(from start: Int, before end: Int) -> (Unicode.Scalar, Int)? {
            guard start < end, text[start] == "`" || text[start] == "~" else { return nil }
            let marker = text[start]
            var at = start
            while at < end, text[at] == marker { at += 1 }
            let length = at - start
            return length >= 3 ? (marker, length) : nil
        }

        func isClosingFence(
            _ fence: (marker: Unicode.Scalar, length: Int),
            from start: Int,
            before end: Int
        ) -> Bool {
            var at = start
            while at < end, text[at] == fence.marker { at += 1 }
            guard at - start >= fence.length else { return false }
            while at < end, isSpace(text[at]) { at += 1 }
            return at == end
        }

        /// Steps over a heading's hashes, a list bullet or number and a task
        /// box. Nil when the whole line is a reference definition, which is a
        /// URL with a label and nothing anybody reads.
        func skipLineMarkers(from start: Int, before end: Int) -> Int? {
            var at = start
            if at < end, text[at] == "[" {
                if let close = find("]", from: at + 1, before: end),
                   close + 1 < end, text[close + 1] == ":", close > at + 1 {
                    // A footnote's definition is prose; only its label is not.
                    guard text[at + 1] == "^" else { return nil }
                    return close + 2
                }
            }
            var hashes = 0
            while at + hashes < end, text[at + hashes] == "#" { hashes += 1 }
            if (1...6).contains(hashes), at + hashes == end || isSpace(text[at + hashes]) {
                return at + hashes
            }
            if at < end, "-*+".unicodeScalars.contains(text[at]),
               at + 1 == end || isSpace(text[at + 1]) {
                at = skipSpaces(from: at + 1, before: end)
            } else {
                var digits = at
                while digits < end, digits - at < 9, isDigit(text[digits]) { digits += 1 }
                if digits > at, digits < end, text[digits] == "." || text[digits] == ")",
                   digits + 1 == end || isSpace(text[digits + 1]) {
                    at = skipSpaces(from: digits + 1, before: end)
                } else {
                    return at
                }
            }
            if at + 2 < end, text[at] == "[", text[at + 2] == "]",
               " xX".unicodeScalars.contains(text[at + 1]),
               at + 3 == end || isSpace(text[at + 3]) {
                at += 3
            }
            return at
        }

        // MARK: Inline

        /// Counts one line's words from `start`. Returns whether the line ends
        /// inside an HTML comment that the next line has to close.
        mutating func scanInline(from start: Int, before end: Int) -> Bool {
            var at = start
            while at < end {
                let scalar = text[at]
                switch scalar {
                case "<":
                    if let skipped = skipAngle(from: at, before: end) {
                        if skipped.unclosedComment { return true }
                        at = skipped.next
                        continue
                    }
                case "!" where at + 1 < end && text[at + 1] == "[":
                    if let after = skipImage(from: at + 1, before: end) {
                        endWord()
                        at = after
                        continue
                    }
                case "]" where at + 1 < end && (text[at + 1] == "(" || text[at + 1] == "["):
                    // The destination of a link, or the label of a reference
                    // to one. The words before the bracket are the link text,
                    // and those are counted.
                    endWord()
                    at = text[at + 1] == "("
                        ? skipBalanced(from: at + 1, before: end)
                        : (find("]", from: at + 2, before: end).map { $0 + 1 } ?? end)
                    continue
                case "[" where at + 1 < end && text[at + 1] == "^":
                    endWord()
                    at = find("]", from: at + 2, before: end).map { $0 + 1 } ?? end
                    continue
                case "&":
                    if let after = skipEntity(from: at, before: end) {
                        endWord()
                        at = after
                        continue
                    }
                case "|":
                    endWord()
                    at += 1
                    continue
                default:
                    break
                }
                take(scalar)
                at += 1
            }
            return false
        }

        mutating func take(_ scalar: Unicode.Scalar) {
            if isSpace(scalar) {
                endWord()
            } else if isIdeograph(scalar) {
                endWord()
                words += 1
            } else {
                inWord = true
                if !wordHasContent, isLetterOrDigit(scalar) { wordHasContent = true }
            }
        }

        mutating func endWord() {
            if inWord, wordHasContent { words += 1 }
            inWord = false
            wordHasContent = false
        }

        /// A tag, a comment, or an autolink, which counts as one word. Nil
        /// when the `<` is just a less-than sign.
        mutating func skipAngle(
            from start: Int, before end: Int
        ) -> (next: Int, unclosedComment: Bool)? {
            if matches("<!--", at: start, before: end) {
                endWord()
                guard let close = find("-->", from: start + 4, before: end) else {
                    return (end, true)
                }
                return (close + 3, false)
            }
            guard start + 1 < end else { return nil }
            let next = text[start + 1]
            guard isASCIILetter(next) || next == "/" || next == "!" || next == "?"
            else { return nil }
            guard let close = find(">", from: start + 1, before: end) else { return nil }
            let inside = text[(start + 1)..<close]
            endWord()
            let isAutolink = !inside.contains(where: isSpace)
                && (find("://", from: start + 1, before: close) != nil
                    || inside.contains("@"))
            if isAutolink { words += 1 }
            return (close + 1, false)
        }

        /// `![alt](destination)` or `![alt][label]`, all of it. Nil when
        /// what follows the `!` is not an image after all.
        func skipImage(from open: Int, before end: Int) -> Int? {
            var depth = 0
            var at = open
            while at < end {
                if text[at] == "[" { depth += 1 }
                if text[at] == "]" {
                    depth -= 1
                    if depth == 0 { break }
                }
                at += 1
            }
            guard at < end else { return nil }
            let after = at + 1
            guard after < end else { return after }
            if text[after] == "(" { return skipBalanced(from: after, before: end) }
            if text[after] == "[" {
                return find("]", from: after + 1, before: end).map { $0 + 1 } ?? end
            }
            return after
        }

        /// Past the parenthesis matching the one at `open`. Destinations can
        /// hold parentheses of their own — Wikipedia's do — so this counts
        /// them rather than stopping at the first close.
        func skipBalanced(from open: Int, before end: Int) -> Int {
            var depth = 0
            var at = open
            while at < end {
                if text[at] == "(" { depth += 1 }
                if text[at] == ")" {
                    depth -= 1
                    if depth == 0 { return at + 1 }
                }
                at += 1
            }
            return end
        }

        /// `&nbsp;`, `&#8212;` and the like, which are spelled with letters
        /// but read as a space or a mark.
        func skipEntity(from start: Int, before end: Int) -> Int? {
            var at = start + 1
            while at < end, at - start <= 32, isASCIILetter(text[at]) || isDigit(text[at])
                || text[at] == "#" {
                at += 1
            }
            guard at < end, text[at] == ";", at - start >= 3 else { return nil }
            return at + 1
        }

        // MARK: Characters

        func find(_ needle: String, from start: Int, before end: Int) -> Int? {
            let pattern = Array(needle.unicodeScalars)
            guard !pattern.isEmpty, start <= end - pattern.count else { return nil }
            var at = start
            while at <= end - pattern.count {
                if matches(pattern, at: at) { return at }
                at += 1
            }
            return nil
        }

        func matches(_ needle: String, at start: Int, before end: Int) -> Bool {
            let pattern = Array(needle.unicodeScalars)
            return start + pattern.count <= end && matches(pattern, at: start)
        }

        func matches(_ pattern: [Unicode.Scalar], at start: Int) -> Bool {
            for offset in pattern.indices where text[start + offset] != pattern[offset] {
                return false
            }
            return true
        }

        func skipSpaces(from start: Int, before end: Int) -> Int {
            var at = start
            while at < end, isSpace(text[at]) { at += 1 }
            return at
        }

        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x20, 0x09, 0x0D, 0x0B, 0x0C: return true
            case 0..<0x80: return false
            default: return scalar.properties.isWhitespace
            }
        }

        func isDigit(_ scalar: Unicode.Scalar) -> Bool {
            (0x30...0x39).contains(scalar.value)
        }

        func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
            (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
        }

        func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.value < 0x80 { return isASCIILetter(scalar) || isDigit(scalar) }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
        }

        /// Scripts written without spaces between words.
        func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.value {
            case 0x3040...0x30FF,  // Hiragana and Katakana
                 0x3400...0x4DBF,  // CJK Extension A
                 0x4E00...0x9FFF,  // CJK Unified Ideographs
                 0xF900...0xFAFF,  // CJK Compatibility Ideographs
                 0x20000...0x2FA1F:  // Extensions B onwards
                return true
            default:
                return false
            }
        }
    }
}
