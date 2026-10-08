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
            id: "sized-images",
            text: """
            <img src="Trip.assets/a%20shot.png" alt="sized" width="300" height="200">
            One dimension: <img src=a.png width=300> and <img src='b.png' height='40'/>.
            Read liberally: <IMG ALT="a > b" SRC="c.png" WIDTH="12">.
            Entities: <img src="d.png?x=1&amp;y=2" alt="&quot;q&quot;">.
            Not images: <imgx src="e.png"> <image src="f.png"> <img> <img src="">.
            Unterminated <img src="g.png" keeps the rest of this line.
            Not a size: <img src="h.png" width="50%" height="0">.
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

    /// Documents for editing through the rendered view.
    ///
    /// Kept out of `documents` so that the formatting fixture, whose case
    /// counts the other READMEs cite, stays exactly as it is. Each puts a
    /// hidden marker beside a line break, which is where an edit made in the
    /// rendered view has to take away Markdown nobody can see — the first is
    /// the shape of the document the bug was reported on.
    public static let editingDocuments: [Document] = [
        Document(
            id: "empty-heading-under-quote",
            text: """
            > **Note: BFS is the shape of the answer**
            > If BFS rings a bell, it visits every node one edge away first. \n\
            ## \n\
            Let's run that on our 5-by-5 grid.
            """
        ),
        Document(
            id: "line-markers",
            text: """
            Paragraph above.
            ## Heading
            #\tTabbed heading
               ### Three spaces in
            >quote without a space
              >  quote with spaces
            > # a hash inside a quote
            ## > a quote mark inside a heading
            ## **bold** heading
            \\## escaped hashes
            ##NoSpace
            ####### seven hashes
            ##
            >
            ## \n\
            Last paragraph.
            """
        ),
        Document(
            id: "fence-neighbours",
            text: """
            ## Before a fence
            ```swift
            ## not a heading
            > not a quote
            ```
            ## After a fence
            ~~~
            code
            ~~~
            > After a tilde fence
            """
        ),
        Document(
            id: "crlf-markers",
            text: "> quoted\r\n## \r\nParagraph\r\n## Heading\r\n> quote\r\n"
        ),
        Document(id: "trailing-empty-heading", text: "Paragraph\n## "),
    ]

    /// One edit that removes a line break the rendered view shows.
    public struct LineEdit: Equatable, Sendable {
        public var kind: String
        public var range: NSRange
        public var replacement: String
    }

    /// The edits that take away a line break, at every line break shown.
    ///
    /// `join` is ⌫ at the start of the line below it, or ⌦ at the end of the
    /// line above, `joinTyping` is typing over it, and `deleteLine` is
    /// deleting the whole line it ends. A CRLF is taken whole, as the text
    /// system takes it. Offsets are in the rendered text.
    public static func lineEdits(inRendered rendered: NSString) -> [LineEdit] {
        var edits: [LineEdit] = []
        var lineStart = 0
        var index = 0
        while index < rendered.length {
            let character = rendered.character(at: index)
            guard [0x0A, 0x0D, 0x2028, 0x2029].contains(character) else {
                index += 1
                continue
            }
            var end = index + 1
            if character == 0x0D, end < rendered.length,
               rendered.character(at: end) == 0x0A {
                end += 1
            }
            let lineBreak = NSRange(location: index, length: end - index)
            edits.append(LineEdit(kind: "join", range: lineBreak, replacement: ""))
            edits.append(LineEdit(kind: "joinTyping", range: lineBreak, replacement: "x"))
            edits.append(
                LineEdit(
                    kind: "deleteLine",
                    range: NSRange(location: lineStart, length: end - lineStart),
                    replacement: ""
                )
            )
            lineStart = end
            index = end
        }
        return edits
    }

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
