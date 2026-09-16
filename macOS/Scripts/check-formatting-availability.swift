// Does formatting refuse inside code, and still work inside a quote, in a
// *real* editor window?
//
// The unit tests hold `MarkdownFormatting` to the rule with source offsets. The
// thing a person does is different in one way that has bitten this editor
// before: the caret they move is in the **rendered** pane, where the fence
// lines and the `> ` markers are not on screen at all, and the selection has to
// travel back through the render model before any command sees it. A rule that
// is right about source offsets and wrong about that mapping passes every unit
// test and still writes `**bold text**` into somebody's code — which is exactly
// what was reported.
//
// So this opens the real `MarkdownEditorView` on a document with a fence, a
// quote and a code span in it, puts the selection where a person would put it,
// and runs the command the toolbar runs. The answers come from the document's
// own text and from what the pane is actually drawing.
//
// The window is positioned off-screen and never ordered front, because the
// person who owns this machine is usually using it.
//
// Built by Scripts/run-formatting-checks.sh against the real app sources.

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
    /// A fence, a quote and a code span, each with a word to aim at that
    /// appears nowhere else.
    static let source = """
    # Notes

    > A quoted sentence.

    ```swift
    let total = 1
    ```

    Call `reload()` when ready.

    """

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

        let documentURL = directory.appendingPathComponent("notes.md")
        try? source.write(to: documentURL, atomically: true, encoding: .utf8)

        var document = MarkdownDocument(text: source)
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
            )
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

        print("Formatting inside code and quotes, in a real editor window")

        guard let textView = firstTextView(under: hosting) else {
            print("  FAIL the rendered pane never appeared in the hierarchy")
            exit(1)
        }
        guard
            let coordinator = textView.delegate as? RichTextEditor.Coordinator,
            let session = coordinator.session
        else {
            print("  FAIL the rendered pane has no session behind it")
            exit(1)
        }
        window.makeFirstResponder(textView)
        settle(for: 0.2)
        check("the rendered pane is focused, as it is for a person", coordinator.hasFocus)

        /// Selects `word` where the *reader* sees it, and lets the pane settle.
        ///
        /// Deliberately searched for in the rendered text, not the source: it
        /// is the rendered offset a person's selection is in, and turning it
        /// back into a source offset is the half of this that unit tests on
        /// source offsets cannot exercise.
        func selectRendered(_ word: String) -> Bool {
            let rendered = textView.string as NSString
            let range = rendered.range(of: word)
            guard range.location != NSNotFound else { return false }
            textView.setSelectedRange(range)
            settle(for: 0.2)
            return true
        }

        // ── Inside a fenced code block ───────────────────────────────────
        //
        // The reported bug. The fence lines are not on screen, so nothing in
        // the rendered pane tells the caret it has left the prose.
        check("the word inside the fence is selectable", selectRendered("total"))
        check(
            "the session knows the selection is in a code block",
            session.codeContext.isCode,
            "it says \(session.codeContext)"
        )
        check("bold is withdrawn inside a fence", !session.isAvailable(.bold))
        check("a link is withdrawn inside a fence", !session.isLinkAvailable)

        let beforeBold = document.text
        session.toggleInline(.bold)
        settle(for: 0.3)
        check(
            "bold writes nothing into a code block",
            document.text == beforeBold,
            "the document became \(document.text.debugDescription)"
        )
        check(
            "and no asterisks appear on screen",
            !textView.string.contains("**"),
            "the pane shows \(textView.string.debugDescription)"
        )

        // ── Inside an inline code span ───────────────────────────────────
        check("the word inside the code span is selectable", selectRendered("reload"))
        check(
            "the session knows the selection is in a code span",
            session.codeContext.isCode,
            "it says \(session.codeContext)"
        )
        check("italic is withdrawn inside a code span", !session.isAvailable(.italic))

        let beforeItalic = document.text
        session.toggleInline(.italic)
        settle(for: 0.3)
        check(
            "italic writes nothing into a code span",
            document.text == beforeItalic,
            "the document became \(document.text.debugDescription)"
        )

        // ── Inside a block quote ─────────────────────────────────────────
        //
        // The other half of the report, and the opposite requirement: bold in
        // a quote is ordinary Markdown, so it has to work *and* its markers
        // have to stay hidden.
        check("the word inside the quote is selectable", selectRendered("quoted"))
        check(
            "the session knows a quote is prose",
            session.codeContext == .prose,
            "it says \(session.codeContext)"
        )
        check("bold is offered inside a quote", session.isAvailable(.bold))

        session.toggleInline(.bold)
        settle(for: 0.4)
        check(
            "bold writes its markers into the source",
            document.text.contains("> A **quoted** sentence."),
            "the document became \(document.text.debugDescription)"
        )
        check(
            "and the markers do not come back on screen",
            !textView.string.contains("**")
                && textView.string.contains("A quoted sentence."),
            "the pane shows \(textView.string.debugDescription)"
        )

        let rendered = textView.string as NSString
        let boldRange = rendered.range(of: "quoted")
        var isDrawnBold = false
        if boldRange.location != NSNotFound,
            let font = textView.textStorage?
                .attribute(.font, at: boldRange.location, effectiveRange: nil)
                as? NSFont
        {
            isDrawnBold = font.fontDescriptor.symbolicTraits.contains(.bold)
        }
        check("and the word is actually drawn bold in the quote", isDrawnBold)

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
