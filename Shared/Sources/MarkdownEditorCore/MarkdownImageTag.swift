import Foundation

/// How an image with a size is written, and read back.
///
/// Markdown has no syntax for image dimensions. The convention every port
/// follows — settled by rendering the candidates through GitHub's own
/// renderer, and recorded in `Contract/README.md` — is that an image with no
/// size stays `![alt](path)` Markdown, and an image with a size becomes an
/// HTML `<img>` tag. Setting a size converts one form to the other, and
/// clearing it converts back.
///
/// The type is deliberately liberal about what it reads and strict about what
/// it writes, because a person may have typed the tag by hand.
public enum MarkdownImageTag {
    /// One `<img>` tag found in a document.
    public struct Parsed: Equatable, Sendable {
        /// The offset just past the closing `>`.
        public let end: Int
        public let destination: String
        public let altText: String
        public let width: Int?
        public let height: Int?

        public init(
            end: Int,
            destination: String,
            altText: String,
            width: Int?,
            height: Int?
        ) {
            self.end = end
            self.destination = destination
            self.altText = altText
            self.width = width
            self.height = height
        }
    }

    /// A width and a height, either of which may be absent.
    public struct Size: Equatable, Sendable {
        public let width: Int?
        public let height: Int?

        public init(width: Int? = nil, height: Int? = nil) {
            self.width = width
            self.height = height
        }

        public static let none = Size()
    }

    /// Which dimension the person just typed, and so which one is authoritative.
    public enum Dimension {
        case width
        case height
    }

    private static let tagStart = "<img"

    /// Parse an `<img>` tag beginning at `location`.
    ///
    /// Returns `nil` when the text is not one, in which case the caller leaves
    /// it as literal text.
    public static func parse(
        _ source: NSString,
        at location: Int,
        end: Int
    ) -> Parsed? {
        guard location >= 0, end <= source.length, location < end else {
            return nil
        }
        let startLength = (tagStart as NSString).length
        guard location + startLength <= end else { return nil }
        guard
            source.substring(
                with: NSRange(location: location, length: startLength)
            ).lowercased() == tagStart
        else { return nil }

        // `<imgx>` shares a prefix with `<img` and is a different element, so
        // the character after the name has to end it.
        if location + startLength < end {
            let next = source.character(at: location + startLength)
            guard isSpace(next) || next == 0x3E || next == 0x2F else {
                return nil
            }
        } else {
            return nil
        }

        var attributes: [String: String] = [:]
        var scan = location + startLength
        // A tag is only a tag once it is closed. Without this, text that merely
        // begins like one — `Check <img src="a.png" in the docs` — would be
        // swallowed to the end of the line.
        var closed = false

        while scan < end {
            let character = source.character(at: scan)

            if isSpace(character) || character == 0x2F {   // whitespace or /
                scan += 1
                continue
            }
            if character == 0x3E {                          // >
                scan += 1
                closed = true
                break
            }

            let nameStart = scan
            while scan < end, isAttributeName(source.character(at: scan)) {
                scan += 1
            }
            guard scan > nameStart else {
                // A character that can neither start a name nor end the tag.
                // Skipping it keeps a malformed tag from looping forever.
                scan += 1
                continue
            }
            let name = source.substring(
                with: NSRange(location: nameStart, length: scan - nameStart)
            ).lowercased()

            var afterName = scan
            while afterName < end, isSpace(source.character(at: afterName)) {
                afterName += 1
            }
            guard
                afterName < end,
                source.character(at: afterName) == 0x3D   // =
            else {
                attributes[name] = ""
                continue
            }

            var valueStart = afterName + 1
            while valueStart < end, isSpace(source.character(at: valueStart)) {
                valueStart += 1
            }
            guard valueStart < end else { return nil }

            let quote = source.character(at: valueStart)
            if quote == 0x22 || quote == 0x27 {             // " or '
                let contentStart = valueStart + 1
                var contentEnd = contentStart
                while contentEnd < end,
                      source.character(at: contentEnd) != quote {
                    contentEnd += 1
                }
                // An unclosed quote means the tag never really ended.
                guard contentEnd < end else { return nil }
                attributes[name] = decodeEntities(
                    source.substring(
                        with: NSRange(
                            location: contentStart,
                            length: contentEnd - contentStart
                        )
                    )
                )
                scan = contentEnd + 1
            } else {
                var contentEnd = valueStart
                while contentEnd < end,
                      !isSpace(source.character(at: contentEnd)),
                      source.character(at: contentEnd) != 0x3E {
                    contentEnd += 1
                }
                attributes[name] = decodeEntities(
                    source.substring(
                        with: NSRange(
                            location: valueStart,
                            length: contentEnd - valueStart
                        )
                    )
                )
                scan = contentEnd
            }
        }

        guard closed else { return nil }

        // An image with nothing to draw is left as text on purpose: an author
        // can see and fix a tag they can read, and cannot fix an empty box.
        let destination = attributes["src"] ?? ""
        guard !destination.isEmpty else { return nil }

        return Parsed(
            end: scan,
            destination: destination,
            altText: attributes["alt"] ?? "",
            width: pixelCount(attributes["width"]),
            height: pixelCount(attributes["height"])
        )
    }

    /// The text for an image reference, in whichever form its size calls for.
    ///
    /// This is the only place that decides between the two, so the rule "HTML
    /// only when it buys something" lives in one place: give an image a size
    /// and it becomes HTML, clear the size and it goes back to being Markdown.
    public static func reference(
        destination: String,
        altText: String = "",
        size: Size = .none
    ) -> String {
        let width = positive(size.width)
        let height = positive(size.height)
        guard width != nil || height != nil else {
            return markdownReference(altText: altText, destination: destination)
        }

        var tag = "<img src=\"\(escapeAttribute(destination))\""
        tag += " alt=\"\(escapeAttribute(altText))\""
        if let width { tag += " width=\"\(width)\"" }
        if let height { tag += " height=\"\(height)\"" }
        return tag + ">"
    }

    /// `![alt](destination)`, with the label escaped and the destination
    /// encoded so the result round-trips.
    ///
    /// The encoding matters most when converting back from the HTML form: an
    /// HTML attribute holds `my file.png` happily, but the same text in
    /// Markdown is not an image at all — GitHub renders it as literal text and
    /// the picture is lost. `encodeDestination` is idempotent, so an
    /// already-encoded path is unharmed.
    public static func markdownReference(
        altText: String,
        destination: String
    ) -> String {
        "![\(escapeLabel(altText))](\(encodeDestination(destination)))"
    }

    /// Escape the characters that would otherwise end a `[…]` label early.
    public static func escapeLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Percent-encode the characters that would end an inline destination
    /// early. Shared by links and images so a URL behaves the same in both.
    public static func encodeDestination(_ destination: String) -> String {
        destination
            .replacingOccurrences(of: "\\", with: "%5C")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    /// A width and a height that keep the shape of `natural`.
    ///
    /// Whichever of the two was last typed is honoured exactly; the other is
    /// derived. Rounding is deliberately kept away from zero, so a very wide,
    /// very short image never derives a height of 0 and vanishes.
    public static func proportionalSize(
        _ requested: Size,
        natural: Size?,
        edited: Dimension
    ) -> Size {
        let typed = edited == .width ? requested.width : requested.height
        guard let typed = positive(typed) else {
            // Clearing one side clears both: half a size is not a size.
            return .none
        }
        guard
            let natural,
            let naturalWidth = positive(natural.width),
            let naturalHeight = positive(natural.height)
        else {
            // An image that has not loaded has no shape to preserve. Inventing
            // one would distort the picture the moment it did load.
            return edited == .width
                ? Size(width: typed, height: nil)
                : Size(width: nil, height: typed)
        }

        switch edited {
        case .width:
            let derived = Double(typed) * Double(naturalHeight)
                / Double(naturalWidth)
            return Size(width: typed, height: max(1, Int(derived.rounded())))
        case .height:
            let derived = Double(typed) * Double(naturalWidth)
                / Double(naturalHeight)
            return Size(width: max(1, Int(derived.rounded())), height: typed)
        }
    }

    // MARK: - Private

    /// A dimension the editor can offer in a number field.
    ///
    /// A value such as `50%` is legal HTML this editor cannot represent, so it
    /// is reported as absent. The image still renders; there is simply no
    /// number to show, and nothing the author typed by hand is rewritten.
    private static func pixelCount(_ value: String?) -> Int? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII) else { return nil }
        guard trimmed.allSatisfy({ $0.isNumber }) else { return nil }
        guard let number = Int(trimmed), number > 0 else { return nil }
        return number
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func isSpace(_ code: unichar) -> Bool {
        code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D
            || code == 0x0C
    }

    private static func isAttributeName(_ code: unichar) -> Bool {
        if code >= 0x61, code <= 0x7A { return true }   // a–z
        if code >= 0x41, code <= 0x5A { return true }   // A–Z
        if code >= 0x30, code <= 0x39 { return true }   // 0–9
        return code == 0x2D || code == 0x5F || code == 0x3A   // - _ :
    }

    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        var rest = Substring(value)

        while let start = rest.firstIndex(of: "&") {
            result += rest[rest.startIndex..<start]
            let afterAmpersand = rest.index(after: start)
            guard
                let semicolon = rest[afterAmpersand...].firstIndex(of: ";"),
                rest.distance(from: afterAmpersand, to: semicolon) <= 8
            else {
                result.append("&")
                rest = rest[afterAmpersand...]
                continue
            }
            let name = String(rest[afterAmpersand..<semicolon])
            result += decodeEntity(name) ?? "&\(name);"
            rest = rest[rest.index(after: semicolon)...]
        }
        return result + rest
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let number: Int?
        if digits.first == "x" || digits.first == "X" {
            number = Int(digits.dropFirst(), radix: 16)
        } else {
            number = Int(digits)
        }
        guard let number, let scalar = safeScalar(number) else { return nil }
        return String(scalar)
    }

    /// Surrogate halves and out-of-range values would produce an invalid
    /// string, so an entity naming one is left alone rather than decoded.
    private static func safeScalar(_ number: Int) -> Unicode.Scalar? {
        guard number > 0, number <= 0x10FFFF else { return nil }
        guard !(number >= 0xD800 && number <= 0xDFFF) else { return nil }
        return Unicode.Scalar(UInt32(number))
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
