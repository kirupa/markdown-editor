import Foundation
import MarkdownEditorCore
import MarkdownEditorCloud

/// Turns the compiled Swift into JSON another language can be tested against.
///
/// The point is narrow and worth stating. This project has three builds of the
/// same editor and is about to have a fourth, and the only reason the web one
/// can be trusted is that it was compared, case by case, against the compiled
/// Swift. That comparison was run from a harness that was never committed, so
/// the claim outlived the means of checking it and no new platform could
/// repeat it. These files are that harness's output, committed: the same
/// documents, the same selections, the same commands, and what the Swift
/// actually produces for each. A port is correct when it reproduces them.
///
/// **Offsets are UTF-16 code units.** Swift's `NSString`, JavaScript strings,
/// C# `string`, and Java `String` all index that way, so the numbers here can
/// be used directly in all of them. Go, Rust, and Python cannot, and a port in
/// one of those has to convert — which is exactly why the corpus contains emoji
/// and a combining family sequence.
public enum ContractFixtures {
    public static let version = 1

    // MARK: - Formatting

    public struct FormattingCase: Codable, Equatable {
        public var document: String
        public var command: String
        public var argument: String?
        public var selection: [Int]
        /// The one range of the document that changed, and what it became.
        ///
        /// The whole resulting text would be simpler to compare against, and
        /// would also be forty times the size — most commands change a handful
        /// of characters in a document that is otherwise identical. Storing the
        /// edit says the same thing in a file small enough to read, and says it
        /// better: an editor applies an edit, and a case that shows one is a
        /// case you can check by eye.
        public var replace: [Int]
        public var with: String
        public var selectionAfter: [Int]
    }

    public struct FormattingHeader: Codable, Equatable {
        public var version: Int
        public var about: String
        public var offsets: String
        public var source: String
        public var caseCount: Int
        public var documents: [ContractCorpus.Document]
    }

    public struct FormattingFixture: Equatable {
        public var header: FormattingHeader
        public var cases: [FormattingCase]
    }

    /// Every command, applied at every selection, in every document.
    public static func formatting() -> FormattingFixture {
        var cases: [FormattingCase] = []
        let commands = Command.all

        for document in ContractCorpus.documents {
            for selection in ContractCorpus.selections(in: document.text) {
                for command in commands {
                    let result = command.apply(document.text, selection)
                    let edit = Self.minimalEdit(from: document.text, to: result.text)
                    cases.append(
                        FormattingCase(
                            document: document.id,
                            command: command.name,
                            argument: command.argument,
                            selection: [selection.location, selection.length],
                            replace: [edit.range.location, edit.range.length],
                            with: edit.replacement,
                            selectionAfter: [result.selection.location, result.selection.length]
                        )
                    )
                }
            }
        }

        return FormattingFixture(
            header: FormattingHeader(
                version: version,
                about: "Every formatting command applied at every interesting selection in every corpus document. Apply `with` over the `replace` range of the named document; the result must equal what the command produced, and the selection must equal `selectionAfter`.",
                offsets: "UTF-16 code units",
                source: "Shared/Sources/MarkdownEditorCore/MarkdownFormatting.swift",
                caseCount: cases.count,
                documents: ContractCorpus.documents
            ),
            cases: cases
        )
    }

    /// The commands a build has to have, in the form the fixture names them.
    struct Command {
        var name: String
        var argument: String?
        var apply: (String, NSRange) -> MarkdownEditResult

        /// Computed rather than stored: the list is built once per run and
        /// never shared, and a stored static of closures is global mutable
        /// state as far as Swift 6 is concerned.
        static var all: [Command] {
            var commands: [Command] = []

            for style in MarkdownInlineStyle.allCases {
                commands.append(
                    Command(name: "toggleInline", argument: String(describing: style)) { text, selection in
                        MarkdownFormatting.toggleInline(style, in: text, selection: selection)
                    }
                )
            }
            for level in 0...6 {
                commands.append(
                    Command(name: "applyHeading", argument: String(level)) { text, selection in
                        MarkdownFormatting.applyHeading(level: level, in: text, selection: selection)
                    }
                )
            }
            for (label, style) in [
                ("bulleted", MarkdownListStyle.bulleted),
                ("numbered", .numbered),
                ("task", .task),
            ] {
                commands.append(
                    Command(name: "toggleList", argument: label) { text, selection in
                        MarkdownFormatting.toggleList(style, in: text, selection: selection)
                    }
                )
            }
            commands.append(
                Command(name: "toggleQuote", argument: nil) { text, selection in
                    MarkdownFormatting.toggleQuote(in: text, selection: selection)
                }
            )
            commands.append(
                Command(name: "wrapCodeBlock", argument: nil) { text, selection in
                    MarkdownFormatting.wrapCodeBlock(in: text, selection: selection)
                }
            )
            commands.append(
                Command(name: "insertNewline", argument: nil) { text, selection in
                    MarkdownFormatting.insertNewline(in: text, selection: selection)
                }
            )
            commands.append(
                Command(name: "insertLink", argument: "https://example.com") { text, selection in
                    MarkdownFormatting.insertLink(
                        destination: "https://example.com", in: text, selection: selection
                    )
                }
            )
            commands.append(
                Command(name: "insertHorizontalRule", argument: nil) { text, selection in
                    MarkdownFormatting.insertHorizontalRule(in: text, selection: selection)
                }
            )
            return commands
        }
    }

    /// The smallest single replacement that turns one string into the other.
    ///
    /// Common prefix and common suffix are trimmed, in UTF-16 units but never
    /// through the middle of a surrogate pair — splitting one would produce a
    /// fixture that cannot be represented as text, which is exactly the failure
    /// the astral corpus document exists to provoke.
    static func minimalEdit(from oldText: String, to newText: String) -> MarkdownTextReplacement {
        let old = oldText as NSString
        let new = newText as NSString

        var prefix = 0
        let maximumPrefix = min(old.length, new.length)
        while prefix < maximumPrefix,
              old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        // Back off a trailing high surrogate, so the prefix ends on a boundary.
        if prefix > 0, prefix < maximumPrefix, isHighSurrogate(old.character(at: prefix - 1)) {
            prefix -= 1
        }

        var suffix = 0
        let maximumSuffix = min(old.length, new.length) - prefix
        while suffix < maximumSuffix,
              old.character(at: old.length - suffix - 1) == new.character(at: new.length - suffix - 1) {
            suffix += 1
        }
        if suffix > 0, suffix < maximumSuffix, isLowSurrogate(old.character(at: old.length - suffix)) {
            suffix -= 1
        }

        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(
            with: NSRange(location: prefix, length: new.length - prefix - suffix)
        )
        return MarkdownTextReplacement(range: range, replacement: replacement)
    }

    private static func isHighSurrogate(_ unit: unichar) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private static func isLowSurrogate(_ unit: unichar) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }

    // MARK: - Render model

    public struct SpanFixture: Codable, Equatable {
        public var style: String
        public var argument: String?
        public var rendered: [Int]
        public var source: [Int]
        public var includesMarkup: Bool
        public var isAtomic: Bool
    }

    public struct RenderCase: Codable, Equatable {
        public var document: String
        public var text: String
        public var spans: [SpanFixture]
    }

    public struct RenderFixture: Codable, Equatable {
        public var version: Int
        public var about: String
        public var offsets: String
        public var source: String
        public var documents: [ContractCorpus.Document]
        public var cases: [RenderCase]
    }

    /// What the reading view shows, and where every part of it came from.
    ///
    /// The source ranges are the half that is easy to skip and impossible to do
    /// without: they are what lets a click in the rendered pane put the caret
    /// in the right place in the source, and what keeps a selection in one view
    /// when switching to the other.
    public static func renderModel() -> RenderFixture {
        let cases = ContractCorpus.documents.map { document in
            let model = MarkdownRenderer.render(document.text)
            return RenderCase(
                document: document.id,
                text: model.text,
                spans: model.spans.map { span in
                    let (style, argument) = describe(span.style)
                    return SpanFixture(
                        style: style,
                        argument: argument,
                        rendered: [span.renderedRange.location, span.renderedRange.length],
                        source: [span.sourceRange.location, span.sourceRange.length],
                        includesMarkup: span.includesMarkup,
                        isAtomic: span.isAtomic
                    )
                }
            )
        }

        return RenderFixture(
            version: version,
            about: "Each corpus document rendered: the text the reading view shows, and every style span with the source range it maps back to.",
            offsets: "UTF-16 code units. Rendered ranges index the rendered text; source ranges index the original document.",
            source: "Shared/Sources/MarkdownEditorCore/MarkdownRenderModel.swift",
            documents: ContractCorpus.documents,
            cases: cases
        )
    }

    private static func describe(_ style: MarkdownRenderStyle) -> (String, String?) {
        switch style {
        case .heading(let level): return ("heading", String(level))
        case .bold: return ("bold", nil)
        case .italic: return ("italic", nil)
        case .underline: return ("underline", nil)
        case .strikethrough: return ("strikethrough", nil)
        case .inlineCode: return ("inlineCode", nil)
        case .codeBlock(let language): return ("codeBlock", language)
        case .quote: return ("quote", nil)
        case .bulletedList: return ("bulletedList", nil)
        case .numberedList: return ("numberedList", nil)
        case .taskList(let checked): return ("taskList", checked ? "checked" : "unchecked")
        case .link(let destination): return ("link", destination)
        case .image(let altText, let destination): return ("image", "\(altText)\u{1F}\(destination)")
        case .horizontalRule: return ("horizontalRule", nil)
        case .escaped: return ("escaped", nil)
        }
    }

    // MARK: - Paths

    public struct PathCase: Codable, Equatable {
        public var function: String
        public var input: [String]
        public var output: String?
        public var error: String?
    }

    public struct PathFixture: Codable, Equatable {
        public var version: Int
        public var about: String
        public var source: String
        public var cases: [PathCase]
    }

    /// The workspace-path arithmetic all four builds share.
    ///
    /// These decide whether two builds can see each other's documents at all:
    /// `documentId` is the Firestore key, so a build that encodes it
    /// differently writes documents the others cannot find, and
    /// `nextAvailableName` is what stops two devices overwriting each other.
    public static func paths() -> PathFixture {
        var cases: [PathCase] = []

        func record(_ function: String, _ input: [String], _ body: () throws -> String) {
            do {
                cases.append(PathCase(function: function, input: input, output: try body(), error: nil))
            } catch {
                cases.append(PathCase(function: function, input: input, output: nil, error: "\(error)"))
            }
        }

        let paths = [
            "", "/", "Notes.md", "/Notes.md", "a/b/c.md", "a//b", "a/./b", "  spaced.md  ",
            "Trip.assets/a shot.png", "Notes", "Notes 2/Out.md", "Ünïcøde/文档.md", "emoji 😀.md",
        ]
        for path in paths {
            record("normalize", [path]) { try CloudPath.normalize(path) }
            record("name", [path]) { CloudPath.name(of: path) }
            record("parent", [path]) { CloudPath.parent(of: path) }
            record("stem", [path]) { CloudPath.stem(of: path) }
            record("fileExtension", [path]) { CloudPath.fileExtension(of: path) }
            record("isMarkdown", [path]) { String(CloudPath.isMarkdown(path)) }
            record("assetsFolderName", [path]) { CloudPath.assetsFolderName(for: path) }
            record("documentId", [path]) { try CloudPath.documentId(for: path) }
        }

        let pairs = [
            ("", "a.md"), ("a", "b.md"), ("a/b", "c.md"), ("Notes", ""), ("Notes", "/x"),
        ]
        for (parent, name) in pairs {
            record("join", [parent, name]) { CloudPath.join(parent, name) }
        }

        let descendancy = [
            ("Notes/In.md", "Notes"), ("Notes 2/Out.md", "Notes"), ("Notes.md", "Notes"),
            ("Notes", "Notes"), ("a/b/c", "a"), ("a/b/c", ""),
        ]
        for (path, folder) in descendancy {
            record("isDescendant", [path, folder]) { String(CloudPath.isDescendant(path, of: folder)) }
        }

        let rewrites = [
            ("Notes/In.md", "Notes", "Journal"), ("Notes", "Notes", "Journal"),
            ("Notes 2/Out.md", "Notes", "Journal"), ("a/b/c.md", "a/b", "x"),
        ]
        for (path, from, to) in rewrites {
            record("rewrite", [path, from, to]) { CloudPath.rewrite(path, from: from, to: to) }
        }

        let collisions: [(Set<String>, String)] = [
            (["Notes.md"], "Notes.md"),
            (["Notes.md", "Notes-2.md"], "Notes.md"),
            (["a.png", "a-2.png", "a-3.png"], "a.png"),
            (["noext", "noext-2"], "noext"),
        ]
        for (taken, name) in collisions {
            record("nextAvailableName", [taken.sorted().joined(separator: "|"), name]) {
                try CloudPath.nextAvailableName(taken: taken, for: name)
            }
        }

        return PathFixture(
            version: version,
            about: "Workspace-path arithmetic: normalisation, naming, descendancy, subtree rewriting, and collision numbering.",
            source: "Shared/Sources/MarkdownEditorCloud/CloudPath.swift",
            cases: cases
        )
    }

    // MARK: - Writing

    /// Stable output, so a regenerated file with no behaviour change is an
    /// empty diff and a real change is legible in review.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// The formatting fixture is one JSON object per line: the header first,
    /// then a case per line.
    ///
    /// Pretty-printed, eight thousand cases came to 2.3 MB, most of it
    /// indentation. One line each is a fifth of that and still diffs a line at
    /// a time, which a single pretty-printed array would not — and it streams,
    /// so a test runner need never hold the whole corpus in memory.
    public static func formattingLines() throws -> Data {
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let fixture = formatting()
        var out = Data()
        out.append(try compact.encode(fixture.header))
        out.append(0x0A)
        for testCase in fixture.cases {
            out.append(try compact.encode(testCase))
            out.append(0x0A)
        }
        return out
    }

    public static func files() throws -> [String: Data] {
        let encoder = encoder()
        return [
            "formatting.jsonl": try formattingLines(),
            "render-model.json": try encoder.encode(renderModel()),
            "paths.json": try encoder.encode(paths()),
        ]
    }
}
