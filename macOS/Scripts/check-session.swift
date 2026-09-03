// Runtime checks for what another app does to the open file.
//
// This file held the split-pane coordination contract too. Split is gone and
// those fifteen checks went with it; these did not, because a file being
// rewritten underneath the editor is still very much a thing that happens.
//
// `MarkdownEditorSession` decides when one pane is allowed to move the other.
// It lives in the app's executable target, so the shared test suite cannot
// import it and it went untested for a long time — which is how E-28 got in:
// `attach` is called from SwiftUI's `updateNSView`, on every keystroke, and it
// was re-running the catch-up meant for a pane *joining* the split.
//
// So this harness compiles the real session against a recording surface and
// asserts what it does. Run with `make check-session`. Exits non-zero on the
// first failure.
//
// It is built by Scripts/run-session-checks.sh, which links it against the
// real app sources.

import AppKit
import MarkdownEditorCore
import MarkdownEditorUI

// MARK: - Harness

@MainActor
private var failures = 0
@MainActor
private var checks = 0

@MainActor
func check(_ label: String, _ passed: Bool, _ detail: String = "") {
    checks += 1
    if passed {
        print("  ok    \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    } else {
        failures += 1
        print("  FAIL  \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
}

/// A pane that records every move the session asks it to make.
@MainActor
final class RecordingSurface: NSObject, MarkdownEditingSurface {
    let name: String
    var sourceText: String
    var selectedSourceRange = NSRange(location: 0, length: 0)
    var hostingWindow: NSWindow? { nil }
    var hasFocus = false
    var normalizedScrollPosition: CGFloat?

    private(set) var scrollWrites: [CGFloat] = []
    private(set) var syncedSelections: [NSRange] = []
    private(set) var directSelections: [NSRange] = []
    private(set) var appliedActions: [String] = []

    init(_ name: String, text: String = "", scroll: CGFloat? = 0.5) {
        self.name = name
        self.sourceText = text
        self.normalizedScrollPosition = scroll
    }

    func forgetMoves() {
        scrollWrites.removeAll()
        syncedSelections.removeAll()
        directSelections.removeAll()
    }

    var moveCount: Int { scrollWrites.count + syncedSelections.count }

    func apply(_ result: MarkdownEditResult, actionName: String) {
        appliedActions.append(actionName)
        sourceText = result.text
        selectedSourceRange = result.selection
    }
    func restore(_ result: MarkdownEditResult) {}
    func commitPendingComposition() {}
    func setSourceSelection(_ selection: NSRange) {
        directSelections.append(selection)
        selectedSourceRange = selection
    }
    func setSynchronizedSourceSelection(_ selection: NSRange) {
        syncedSelections.append(selection)
        selectedSourceRange = selection
    }
    func setNormalizedScrollPosition(_ position: CGFloat) {
        scrollWrites.append(position)
        normalizedScrollPosition = position
    }
    func focus() {}
}

// MARK: - Checks

// MARK: - Changes made by another app

/// Spins the run loop until `condition` holds. The file monitor delivers on a
/// background queue and hops to the main one, so a synchronous harness sees
/// nothing at all unless it lets the main queue run.
@MainActor
func waitUntil(
    _ timeout: TimeInterval = 5,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(0.02)
        )
    }
    return condition()
}

/// Writes the way nearly every editor does: to a temporary file, then rename
/// over the target. That unlinks the inode the monitor is holding, which is
/// the case a naive watcher notices once and then never again.
func replaceAtomically(_ url: URL, with text: String) {
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".swap-\(UUID().uuidString)")
    try? text.write(to: temporary, atomically: false, encoding: .utf8)
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporary)
}

@MainActor
func withScratchDocument(
    _ text: String,
    _ body: (URL) -> Void
) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mde-external-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("Notes.md")
    try? text.write(to: url, atomically: true, encoding: .utf8)
    body(url)
}

/// The whole point of the feature: a change made elsewhere on the device is
/// noticed, and it is either shown or offered rather than lost.
@MainActor
func checkExternalChangesReachTheEditor() {
    print("\nchanges made by another app")

    let original = "# Notes\n\nOne.\n"
    withScratchDocument(original) { url in
        let session = MarkdownEditorSession(
            fileURL: url,
            initialText: original
        )
        let pane = RecordingSurface("SOURCE", text: original)
        pane.hasFocus = true
        session.attach(pane)
        session.startWatchingFile(text: original)

        // Nothing unsaved here, so nothing of this person's is at stake.
        let theirs = "# Notes\n\nOne.\n\nTwo, from somewhere else.\n"
        replaceAtomically(url, with: theirs)

        check(
            "an external write is noticed",
            waitUntil {
                if case .reloadPending = session.externalChange.state {
                    return true
                }
                return false
            },
            "state \(session.externalChange.state)"
        )

        // What the view does when it sees `.reloadPending`.
        if case let .reloadPending(text) = session.externalChange.state {
            session.applyExternalText(text, actionName: "Refresh")
            session.externalChange.acknowledgeReload()
        }

        check(
            "the new text reaches the editor",
            pane.sourceText == theirs,
            "editor holds \(pane.sourceText.debugDescription)"
        )
        check(
            "it arrives as one named, undoable edit",
            pane.appliedActions == ["Refresh"],
            "actions \(pane.appliedActions)"
        )
        check(
            "the banner says so afterwards",
            session.externalChange.state == .updated,
            "state \(session.externalChange.state)"
        )
        check(
            "and saving is not held up",
            !session.isSavingSuspended
        )

        // Now with unsaved edits on screen. Both versions hold work, so the
        // app must not choose.
        let mine = theirs + "\nMine, not yet saved.\n"
        pane.sourceText = mine
        session.externalChange.noteEditorText(mine)

        let alsoTheirs = theirs + "\nTheirs, second pass.\n"
        replaceAtomically(url, with: alsoTheirs)

        check(
            "a second external write is still noticed",
            waitUntil { session.externalChange.state.isConflicted },
            "state \(session.externalChange.state)"
        )
        check(
            "a clash is never applied silently",
            pane.sourceText == mine,
            "editor holds \(pane.sourceText.debugDescription)"
        )
        check(
            "autosave is held while it is unresolved",
            session.isSavingSuspended
        )

        session.keepMyVersion()
        check(
            "keeping mine lets saving resume",
            !session.isSavingSuspended
        )
        check(
            "keeping mine leaves the text on screen alone",
            pane.sourceText == mine
        )

        // Reload from Disk, invoked from the File menu rather than by an
        // event, after the watcher has stopped calling this file news.
        let latest = "# Notes\n\nRewritten entirely.\n"
        replaceAtomically(url, with: latest)
        _ = waitUntil(1) { false }
        session.reloadFromDisk()
        check(
            "Reload from Disk shows the file as it now stands",
            pane.sourceText == latest,
            "editor holds \(pane.sourceText.debugDescription)"
        )
    }
}

/// The failure mode that makes a feature like this worse than not having one:
/// the editor saves every 1.5 seconds, so its own writes must never come back
/// as somebody else's.
@MainActor
func checkOwnSavesAreNotReportedBack() {
    print("\nthe app's own saves are not mistaken for somebody else's")

    let original = "# Notes\n\nOne.\n"
    withScratchDocument(original) { url in
        let session = MarkdownEditorSession(
            fileURL: url,
            initialText: original
        )
        let pane = RecordingSurface("SOURCE", text: original)
        pane.hasFocus = true
        session.attach(pane)
        session.startWatchingFile(text: original)

        // An autosave: the text is announced, written, and declared.
        let typed = original + "\nTyped here.\n"
        pane.sourceText = typed
        session.externalChange.noteEditorText(typed)
        session.externalChange.noteSaved()
        replaceAtomically(url, with: typed)

        _ = waitUntil(1.5) { session.externalChange.state != .idle }
        check(
            "an announced save stays quiet",
            session.externalChange.state == .idle,
            "state \(session.externalChange.state)"
        )

        // File ▸ Save goes through NSDocument and announces nothing. The only
        // evidence those bytes are ours is that they match the screen.
        let saved = typed + "\nSaved with the menu.\n"
        pane.sourceText = saved
        session.externalChange.noteEditorText(saved)
        replaceAtomically(url, with: saved)

        _ = waitUntil(1.5) { session.externalChange.state != .idle }
        check(
            "an unannounced save matching the screen stays quiet too",
            session.externalChange.state == .idle,
            "state \(session.externalChange.state)"
        )

        // The late event: autosave writes, then somebody types on before the
        // event lands. The file legitimately differs from the screen with
        // nobody else involved.
        let inFlight = saved + "\nA.\n"
        pane.sourceText = inFlight
        session.externalChange.noteEditorText(inFlight)
        session.externalChange.noteSaved()
        replaceAtomically(url, with: inFlight)
        let typedOn = inFlight + "B.\n"
        pane.sourceText = typedOn
        session.externalChange.noteEditorText(typedOn)

        _ = waitUntil(1.5) { session.externalChange.state != .idle }
        check(
            "a save whose event arrives late stays quiet",
            session.externalChange.state == .idle,
            "state \(session.externalChange.state)"
        )

        // And after all that, a real external change is still reported.
        replaceAtomically(url, with: "# Notes\n\nSomebody else entirely.\n")
        check(
            "a genuine change afterwards is still reported",
            waitUntil { session.externalChange.state != .idle },
            "state \(session.externalChange.state)"
        )
    }
}

// MARK: - Run

@MainActor
func runChecks() -> Int32 {
    print("changes made by another app")
    checkExternalChangesReachTheEditor()
    checkOwnSavesAreNotReportedBack()

    print("")
    if failures == 0 {
        print("\(checks)/\(checks) checks passed")
        return 0
    }
    print("\(failures) of \(checks) checks FAILED")
    return 1
}

@main
struct CheckSession {
    static func main() {
        let status = MainActor.assumeIsolated { runChecks() }
        exit(status)
    }
}
