import Foundation
import MarkdownEditorContract
import Testing

@testable import MarkdownEditorCore

/// Invariants that must hold for **every** formatting command, on every
/// document in the shared corpus, at every interesting selection in it.
///
/// The rest of the formatting tests are examples: this input produces that
/// output. Examples are precise but they only cover what someone thought to
/// write down, and the bugs that reach a text editor are the combinations
/// nobody pictured — a command run with the caret between the two halves of
/// an emoji, or on the empty document, or across the end of the last line.
///
/// These tests take the opposite approach. They say nothing about what any
/// command produces and everything about what no command may ever do: return
/// a selection outside its own text, split a character in half, or lose the
/// document. 7,667 command/selection combinations run in about a second, and
/// any one of them failing names the exact document, selection, and command
/// to reproduce.
@Suite("Markdown formatting invariants")
struct MarkdownFormattingInvariantTests {
    // MARK: - Every command, exercised uniformly

    /// One formatting command, named so a failure says which.
    struct Command {
        var name: String
        var run: (String, NSRange) -> MarkdownEditResult
    }

    /// Every command the editor exposes that rewrites the document.
    ///
    /// `setImageSize` is excluded: it is not a general text command but one
    /// that acts on an image the caller has already located, and it is
    /// covered by its own tests.
    static var commands: [Command] {
        var commands: [Command] = []

        for style in MarkdownInlineStyle.allCases {
            commands.append(
                Command(name: "toggleInline(\(style))") { text, selection in
                    MarkdownFormatting.toggleInline(
                        style,
                        in: text,
                        selection: selection
                    )
                }
            )
        }

        for level in 0...6 {
            commands.append(
                Command(name: "applyHeading(\(level))") { text, selection in
                    MarkdownFormatting.applyHeading(
                        level: level,
                        in: text,
                        selection: selection
                    )
                }
            )
        }

        let listStyles: [(String, MarkdownListStyle)] = [
            ("bulleted", .bulleted),
            ("numbered", .numbered),
            ("task", .task),
        ]
        for (name, style) in listStyles {
            commands.append(
                Command(name: "toggleList(\(name))") { text, selection in
                    MarkdownFormatting.toggleList(
                        style,
                        in: text,
                        selection: selection
                    )
                }
            )
        }

        commands.append(
            Command(name: "toggleQuote") { text, selection in
                MarkdownFormatting.toggleQuote(in: text, selection: selection)
            }
        )
        commands.append(
            Command(name: "wrapCodeBlock") { text, selection in
                MarkdownFormatting.wrapCodeBlock(in: text, selection: selection)
            }
        )
        commands.append(
            Command(name: "insertNewline") { text, selection in
                MarkdownFormatting.insertNewline(in: text, selection: selection)
            }
        )
        commands.append(
            Command(name: "insertHorizontalRule") { text, selection in
                MarkdownFormatting.insertHorizontalRule(
                    in: text,
                    selection: selection
                )
            }
        )
        commands.append(
            Command(name: "insertLink") { text, selection in
                MarkdownFormatting.insertLink(
                    destination: "https://example.com/a b",
                    in: text,
                    selection: selection
                )
            }
        )
        commands.append(
            Command(name: "insertImage") { text, selection in
                MarkdownFormatting.insertImage(
                    destination: "pictures/a b.png",
                    altText: "Alt",
                    in: text,
                    selection: selection
                )
            }
        )
        return commands
    }

    /// Every command against every corpus document at every selection.
    static func forEachCase(
        _ body: (String, NSRange, Command, MarkdownEditResult) -> Void
    ) {
        for document in ContractCorpus.documents {
            for selection in ContractCorpus.selections(in: document.text) {
                for command in Self.commands {
                    let result = command.run(document.text, selection)
                    body(document.text, selection, command, result)
                }
            }
        }
    }

    // MARK: - The invariants

    /// The commonest way an editor crashes: a command returns a selection
    /// that does not fit the text it also returned, and the next thing to
    /// touch the text view raises an out-of-range exception.
    @Test("Every command returns a selection inside its own text")
    func selectionIsAlwaysInBounds() {
        var checked = 0
        Self.forEachCase { _, selection, command, result in
            let length = (result.text as NSString).length
            let end = result.selection.location + result.selection.length
            #expect(
                result.selection.location >= 0
                    && result.selection.length >= 0
                    && end <= length,
                """
                \(command.name) at \(selection) returned selection \
                \(result.selection) for text of length \(length)
                """
            )
            checked += 1
        }
        // If the corpus or the command list is ever emptied by accident the
        // suite would pass while checking nothing.
        #expect(checked > 5000, "only \(checked) combinations were checked")
    }

    /// Text is stored as UTF-16, and a character outside the Basic
    /// Multilingual Plane — an emoji, most obviously — occupies two code
    /// units. A selection endpoint landing between them is not a position in
    /// the text; using one corrupts the document and can crash the layout
    /// system. This is the single most common porting bug in this codebase's
    /// history, which is why the corpus carries an `astral` document.
    @Test("No command returns a selection splitting a character")
    func selectionNeverSplitsACharacter() {
        Self.forEachCase { _, selection, command, result in
            let text = result.text as NSString
            for offset in [
                result.selection.location,
                result.selection.location + result.selection.length,
            ] {
                guard offset > 0, offset < text.length else { continue }
                let isSplit =
                    isLowSurrogate(text.character(at: offset))
                    && isHighSurrogate(text.character(at: offset - 1))
                #expect(
                    !isSplit,
                    """
                    \(command.name) at \(selection) put an endpoint at \
                    \(offset), between the halves of a surrogate pair
                    """
                )
            }
        }
    }

    /// A formatting command adds or removes markup. None of them is a delete
    /// command, so none may discard the document — the failure mode where a
    /// command run at an awkward selection returns the empty string.
    @Test("No command discards the document")
    func documentIsNeverDiscarded() {
        for document in ContractCorpus.documents where !document.text.isEmpty {
            for selection in ContractCorpus.selections(in: document.text) {
                for command in Self.commands {
                    let result = command.run(document.text, selection)
                    #expect(
                        !result.text.isEmpty,
                        """
                        \(command.name) at \(selection) emptied the \
                        \(document.id) document
                        """
                    )
                }
            }
        }
    }

    /// Commands are given selections that have already been clamped by the
    /// caller in normal use, but a stale selection outliving an edit is a
    /// real situation — an undo, or a synchronised pane applying a selection
    /// captured before the text changed. A command must clamp rather than
    /// trap.
    @Test("Out-of-range selections are clamped, not trapped")
    func outOfRangeSelectionsAreClamped() {
        for document in ContractCorpus.documents {
            let length = (document.text as NSString).length
            let hostile = [
                NSRange(location: length + 1, length: 0),
                NSRange(location: length + 50, length: 0),
                NSRange(location: 0, length: length + 25),
                NSRange(location: max(0, length - 1), length: 100),
                NSRange(location: length, length: 10),
            ]
            for selection in hostile {
                for command in Self.commands {
                    let result = command.run(document.text, selection)
                    let resultLength = (result.text as NSString).length
                    #expect(
                        result.selection.location >= 0
                            && result.selection.location
                                + result.selection.length <= resultLength,
                        """
                        \(command.name) given out-of-range \(selection) on \
                        \(document.id) returned \(result.selection) for \
                        length \(resultLength)
                        """
                    )
                }
            }
        }
    }

    /// Running a command and then running it again on the range it reports
    /// must not run away — the text has to settle rather than grow every
    /// time. This catches a marker that is added but never recognised on the
    /// way back, which is how "bold" ends up producing `****text****`.
    ///
    /// The property is only well defined where the toggle is unambiguous.
    /// Wrapping `and *ligature` in italics has no correct answer, because the
    /// selection already contains an unclosed marker; nor does adding a
    /// backtick immediately before a ``` fence, where the new delimiter joins
    /// the fence and lengthens it. Both are genuine ambiguities in Markdown
    /// rather than defects here, so the check covers selections whose text
    /// *and immediate neighbours* are free of marker characters — the case a
    /// writer actually hits, and 645 combinations of it.
    ///
    /// Ambiguous selections are not skipped altogether: they are still
    /// covered by every safety invariant above. Only the question of what the
    /// text should settle to is set aside.
    @Test("Toggling an inline style twice restores the text")
    func inlineTogglesAreInvolutions() {
        var covered = 0
        for document in ContractCorpus.documents where !document.text.isEmpty {
            let source = document.text as NSString
            for selection in ContractCorpus.selections(in: document.text)
            where selection.length > 0 {
                guard Self.isUnambiguousToggle(selection, in: source) else {
                    continue
                }
                for style in MarkdownInlineStyle.allCases {
                    let once = MarkdownFormatting.toggleInline(
                        style,
                        in: document.text,
                        selection: selection
                    )
                    let twice = MarkdownFormatting.toggleInline(
                        style,
                        in: once.text,
                        selection: once.selection
                    )
                    #expect(
                        twice.text == document.text,
                        """
                        \(style) twice at \(selection) in \(document.id) \
                        did not restore the text
                        """
                    )
                    covered += 1
                }
            }
        }
        // The exclusion rule must not quietly swallow the whole corpus.
        #expect(covered > 500, "only \(covered) unambiguous toggles were checked")
    }

    /// Whether toggling a style over this selection has one obvious answer.
    ///
    /// The selection is widened by a character at each end, because a new
    /// delimiter placed against an existing marker merges with it — that is
    /// what turns a ``` fence into a ```` one.
    private static func isUnambiguousToggle(
        _ selection: NSRange,
        in source: NSString
    ) -> Bool {
        let markers: Set<Character> = ["*", "_", "~", "`", "<", ">"]
        let start = max(0, selection.location - 1)
        let end = min(
            source.length,
            selection.location + selection.length + 1
        )
        let neighbourhood = source.substring(
            with: NSRange(location: start, length: end - start)
        )
        if neighbourhood.contains(where: { markers.contains($0) }) {
            return false
        }
        let selected = source.substring(with: selection)
        return !selected.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    /// Applying the same heading level twice must be the same as applying it
    /// once, or the markers accumulate into `## ## Title`.
    @Test("Applying a heading level is idempotent")
    func headingIsIdempotent() {
        for document in ContractCorpus.documents {
            for selection in ContractCorpus.selections(in: document.text) {
                for level in 1...6 {
                    let once = MarkdownFormatting.applyHeading(
                        level: level,
                        in: document.text,
                        selection: selection
                    )
                    let twice = MarkdownFormatting.applyHeading(
                        level: level,
                        in: once.text,
                        selection: once.selection
                    )
                    #expect(
                        twice.text == once.text,
                        """
                        heading \(level) applied twice at \(selection) in \
                        \(document.id) differs from applying it once
                        """
                    )
                }
            }
        }
    }

    /// Every command must cope with the empty document. It is the state the
    /// app starts in, and the state a writer returns to by selecting all and
    /// deleting.
    @Test("Every command works on an empty document")
    func everyCommandHandlesTheEmptyDocument() {
        for command in Self.commands {
            let result = command.run("", NSRange(location: 0, length: 0))
            let length = (result.text as NSString).length
            #expect(
                result.selection.location >= 0
                    && result.selection.location + result.selection.length
                        <= length,
                "\(command.name) on the empty document returned \(result.selection)"
            )
        }
    }

    private func isHighSurrogate(_ unit: unichar) -> Bool {
        (0xD800...0xDBFF).contains(unit)
    }

    private func isLowSurrogate(_ unit: unichar) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }
}
