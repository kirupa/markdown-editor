import Foundation
import MarkdownEditorCore
import MarkdownEditorCloud

/// The documents every build is checked against.
///
/// Chosen to cover the parts of the dialect that a reimplementation gets wrong:
/// the boundary rules for emphasis, backtick runs of different lengths, lazy
/// quote continuation, ordered lists that do not start at 1, task markers,
/// escapes, and — the one that quietly breaks ports — text outside the Basic
/// Multilingual Plane, where one visible character is two UTF-16 code units.
public enum ContractCorpus {
    public struct Document: Codable, Equatable, Sendable {
        public var id: String
        public var text: String
    }

    public static let documents: [Document] = [
        Document(id: "empty", text: ""),
        Document(id: "plain", text: "One plain paragraph with no markup at all.\n"),
        Document(
            id: "headings",
            text: """
            # Title
            Body under the title.

            ## Subheading
            ### Third level
            ####### Seven hashes is not a heading
               # Three spaces still is
            #NoSpace is not a heading
            """
        ),
        Document(
            id: "emphasis",
            text: """
            Some **bold** and *italic* and ***both***.
            snake_case_stays_plain but _this is italic_.
            A~~strike~~through, and __underscored bold__.
            intra*word*emphasis with asterisks.
            """
        ),
        Document(
            id: "code",
            text: """
            Inline `code` and ``a `tick` inside`` and ` padded `.

            ```swift
            let x = 1
            ```

            Trailing text.
            """
        ),
        Document(
            id: "lists",
            text: """
            - first
            - second
              - nested
            * star bullet
            + plus bullet

            1. one
            2. two
            7. seven starts here
            """
        ),
        Document(
            id: "tasks",
            text: """
            - [ ] unchecked
            - [x] checked
            - [X] capital
            - [] not a task
            """
        ),
        Document(
            id: "quotes",
            text: """
            > quoted line
            > second quoted line
            lazy continuation
            >> nested quote

            Not quoted.
            """
        ),
        Document(
            id: "links",
            text: """
            A [link](https://example.com) and an ![image](Trip.assets/a%20shot.png).
            A [link with **bold**](https://example.com/x) inside.
            Bare https://example.com is not a link.
            """
        ),
        Document(
            id: "rules-and-escapes",
            text: """
            Above.

            ---

            Below \\*not italic\\* and \\# not a heading.
            A backslash at the end \\\\
            """
        ),
        Document(
            id: "astral",
            text: """
            Emoji 😀 then **bold 🇬🇧 flag** and *ligature ﬁ*.
            A family 👨‍👩‍👧‍👦 spans several code units.
            """
        ),
        Document(
            id: "line-endings",
            text: "First line\r\nSecond line\r\n\r\n- bullet after a blank\r\n\tTabbed line\n"
        ),
        Document(
            id: "mixed",
            text: """
            # Trip notes

            Some **bold** text, a [link](https://example.com), and:

            - [ ] pack
            - [x] book train

            > A quote with `code` in it.

            ![shot](Trip.assets/shot.png)

            1. first
            2. second
            """
        ),
    ]

    /// Where a caret or selection is placed in each document.
    ///
    /// Line starts and line ends are where off-by-one errors live, so every one
    /// of them is used, plus spans that cross a line boundary so the
    /// line-oriented commands are exercised on more than one line at a time.
    public static func selections(in text: String) -> [NSRange] {
        let source = text as NSString
        if source.length == 0 { return [NSRange(location: 0, length: 0)] }

        var offsets: Set<Int> = [0, source.length]
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: source.length),
            options: .byLines
        ) { _, range, enclosing, _ in
            offsets.insert(range.location)
            offsets.insert(range.location + range.length)
            offsets.insert(enclosing.location + enclosing.length)
        }
        // Two interior points, to catch anything that only ever looks at line
        // boundaries.
        offsets.insert(source.length / 3)
        offsets.insert(source.length / 2)

        let sorted = offsets.filter { $0 >= 0 && $0 <= source.length }.sorted()

        var ranges: [NSRange] = sorted.map { NSRange(location: $0, length: 0) }
        for (index, start) in sorted.enumerated() {
            if index + 1 < sorted.count {
                ranges.append(NSRange(location: start, length: sorted[index + 1] - start))
            }
            if index + 2 < sorted.count {
                ranges.append(NSRange(location: start, length: sorted[index + 2] - start))
            }
        }
        return ranges.filter { $0.location + $0.length <= source.length }
    }
}
