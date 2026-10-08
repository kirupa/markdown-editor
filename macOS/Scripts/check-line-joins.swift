// Does ⌫ on the blank line under a quote take the caret to the end of the
// quote, and do nothing else, in a *real* editor window?
//
// The unit tests hold `sourceRange(replacing:with:)` to the rule in rendered
// and source offsets, and the Contract holds every build to the same answers.
// What neither sees is the path a key press takes: the text view deciding what
// ⌫ removes from what it draws, the delegate turning that into an edit of the
// source, the pane drawing again, and the caret being put back. The report was
// that path showing `##` — an empty heading the pane drew as a blank line,
// whose marker the old mapping left behind on the end of the quote.
//
// So this opens the real `MarkdownEditorView` on the document from the report,
// puts the caret where the writer put it, and sends the commands the keys
// send. The answers come from the document's own text, from what the pane is
// drawing, and from where its caret is.
//
// The window is positioned off-screen and never ordered front, because the
// person who owns this machine is usually using it.
//
// Built by Scripts/run-line-join-checks.sh against the real app sources.

import AppKit
import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

@MainActor
private var failures = 0
@MainActor
private var checks = 0

@MainActor
func check(
    _ label: String,
    _ passed: Bool,
    _ detail: @autoclosure () -> String = ""
) {
    checks += 1
    if passed {
        print("  ok   \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

@MainActor
func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}

@MainActor
func firstTextView(under root: NSView) -> RichMarkdownTextView? {
    descendants(of: root).compactMap { $0 as? RichMarkdownTextView }.first
}

@main
@MainActor
enum Harness {
    /// The document from the report: an empty heading between a quote and
    /// the paragraph after it, which the pane draws as a blank line. Spelled
    /// out rather than written as a block literal, because the quote's last
    /// line ends in a space that an editor would quietly trim.
    static let quote =
        "> **Note: BFS is the shape of the answer**\n"
        + "> If BFS rings a bell, it visits every node one edge away first. \n"
    static let below = "Let's run that on our 5-by-5 grid."
    static let reported = quote + "## \n" + below
    /// What every one of the edits below should leave: the blank line gone,
    /// and nothing else.
    static let joined = quote + below

    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let documentURL = directory.appendingPathComponent("bug.md")
        try? reported.write(to: documentURL, atomically: true, encoding: .utf8)

        var document = MarkdownDocument(text: reported)
        var themeColor = EditorThemeColor.blue.rawValue
        var appearance = EditorAppearanceMode.light.rawValue

        let view = MarkdownEditorView(
            document: Binding(get: { document }, set: { document = $0 }),
            fileURL: documentURL,
            themeColorRawValue: Binding(
                get: { themeColor },
                set: { themeColor = $0 }
            ),
            appearanceModeRawValue: Binding(
                get: { appearance },
                set: { appearance = $0 }
            ),
            typefaceRawValue: .constant(EditorTypeface.sans.rawValue),
            textScale: .constant(1)
        )

        let frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = frame

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -50_000, y: -50_000))
        window.orderBack(nil)

        settle(for: 1.2)
        hosting.layoutSubtreeIfNeeded()
        settle(for: 0.6)

        print("Removing a blank line through the rendered pane, in a real editor window")

        guard let textView = firstTextView(under: hosting) else {
            print("  FAIL the rendered pane never appeared in the hierarchy")
            exit(1)
        }
        guard let coordinator = textView.delegate as? RichTextEditor.Coordinator else {
            print("  FAIL the rendered pane has no coordinator behind it")
            exit(1)
        }
        window.makeFirstResponder(textView)
        settle(for: 0.2)

        let blank = (textView.string as NSString).range(of: "\n\n" + below)
        guard blank.location != NSNotFound else {
            print(
                "  FAIL the pane does not draw the empty heading as a blank line — "
                    + "it shows \(textView.string.debugDescription)"
            )
            exit(1)
        }
        // Where the writer put the caret: on the blank line, in the gap
        // between the quote and the paragraph.
        let blankLine = blank.location + 1
        let endOfQuote = blankLine - 1
        let sourceEndOfQuote = (quote as NSString).length - 1
        let sourceStartOfBelow = (quote as NSString).length

        check(
            "the pane draws the empty heading as a blank line, with no marker",
            !textView.string.contains("#"),
            "the pane shows \(textView.string.debugDescription)"
        )

        func place(_ location: Int, length: Int = 0) {
            textView.setSelectedRange(NSRange(location: location, length: length))
            settle(for: 0.2)
        }

        func caretIs(rendered: Int, source: Int) -> Bool {
            textView.selectedRange() == NSRange(location: rendered, length: 0)
                && coordinator.selectedSourceRange == NSRange(location: source, length: 0)
        }

        func whereTheCaretIs() -> String {
            "it is at \(textView.selectedRange().location) on screen, "
                + "\(coordinator.selectedSourceRange.location) in the source"
        }

        /// The blank line gone, and nothing else: not in the source, and not
        /// a marker surfacing on screen.
        func expectJoined(_ label: String) {
            check(
                "\(label) removes the blank line from the source, and only that",
                document.text == joined,
                "the document became \(document.text.debugDescription)"
            )
            check(
                "and no marker appears on screen",
                !textView.string.contains("#"),
                "the pane shows \(textView.string.debugDescription)"
            )
        }

        /// Takes the edit back the way ⌘Z does. The undo group only closes
        /// when the run loop turns over, which `settle` lets it do.
        func expectUndone(_ label: String) {
            textView.undoManager?.undo()
            settle(for: 0.4)
            check(
                "undoing \(label) brings the blank line back in one step",
                document.text == reported
                    && (textView.string as NSString).range(of: "\n\n" + below) == blank,
                "the document became \(document.text.debugDescription)"
            )
        }

        // ── ← from the blank line ────────────────────────────────────────
        //
        // The key a "back arrow" could also mean. It moves; it never edits.
        place(blankLine)
        textView.moveLeft(nil)
        settle(for: 0.2)
        check(
            "← from the blank line moves to the end of the quote",
            caretIs(rendered: endOfQuote, source: sourceEndOfQuote),
            whereTheCaretIs()
        )
        check(
            "and changes nothing",
            document.text == reported && !textView.string.contains("#"),
            "the document became \(document.text.debugDescription)"
        )

        // ── ⌫ on the blank line ──────────────────────────────────────────
        //
        // The report: the caret belongs at the end of the quote, and that is
        // all that should change.
        place(blankLine)
        textView.deleteBackward(nil)
        settle(for: 0.4)
        expectJoined("⌫ on the blank line")
        check(
            "the caret is at the end of the quote",
            caretIs(rendered: endOfQuote, source: sourceEndOfQuote),
            whereTheCaretIs()
        )
        expectUndone("⌫ on the blank line")

        // ── ⌦ at the end of the quote ────────────────────────────────────
        place(endOfQuote)
        textView.deleteForward(nil)
        settle(for: 0.4)
        expectJoined("⌦ at the end of the quote")
        check(
            "the caret stays at the end of the quote",
            caretIs(rendered: endOfQuote, source: sourceEndOfQuote),
            whereTheCaretIs()
        )
        expectUndone("⌦ at the end of the quote")

        // ── ⌫ at the start of the paragraph below ────────────────────────
        //
        // The same text as ⌫ on the blank line, so only the caret, left at the
        // start of the paragraph, says which line break went.
        place(blankLine + 1)
        textView.deleteBackward(nil)
        settle(for: 0.4)
        expectJoined("⌫ at the start of the paragraph below")
        check(
            "the caret stays at the start of the paragraph",
            caretIs(rendered: blankLine, source: sourceStartOfBelow),
            whereTheCaretIs()
        )
        expectUndone("⌫ at the start of the paragraph below")

        // ── Cutting the blank line ───────────────────────────────────────
        //
        // Through the coordinator, which is what ⌘X calls once it has copied:
        // ⌘X itself would put this on the clipboard of whoever is using the
        // machine.
        place(blankLine, length: 1)
        coordinator.replaceSelection(withMarkdown: "", actionName: "Cut")
        settle(for: 0.4)
        expectJoined("cutting the blank line")
        check(
            "the caret is where the blank line was",
            caretIs(rendered: blankLine, source: sourceStartOfBelow),
            whereTheCaretIs()
        )
        expectUndone("cutting the blank line")

        print("")
        if failures == 0 {
            print("ALL PASS (\(checks) checks)")
            exit(0)
        }
        print("\(failures) of \(checks) checks failed")
        exit(1)
    }

    /// SwiftUI builds its AppKit children on later run-loop passes, so the
    /// hierarchy does not exist immediately after hosting.
    private static func settle(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
