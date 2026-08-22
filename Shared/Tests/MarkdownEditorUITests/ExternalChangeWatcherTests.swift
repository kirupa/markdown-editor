import Foundation
import Testing

@testable import MarkdownEditorUI

/// Exercises the watcher against a real file, because the parts worth
/// doubting are exactly the parts a fake would paper over: whether a kqueue
/// source survives another program replacing the file, and whether the
/// editor's own writes stay quiet.
///
/// Serialised because each test arms a file-system source and waits on real
/// events; running them at once makes the waits fight for the main queue and
/// turns a slow machine into a flaky suite.
@MainActor
@Suite("External change watching", .serialized)
struct ExternalChangeWatcherTests {
    /// Long enough to cover the monitor's own 150 ms settle delay several
    /// times over, short enough that a genuine failure is not a coffee break.
    private static let timeout: TimeInterval = 5

    // MARK: - The monitor

    @Test("A write in place is noticed")
    func writeInPlaceIsNoticed() async throws {
        let file = try TemporaryFile(contents: "one")
        let counter = ChangeCounter()
        let monitor = FileChangeMonitor(url: file.url) { counter.increment() }
        defer { monitor.stop() }

        try await settle()
        try "two".write(to: file.url, atomically: false, encoding: .utf8)

        try await counter.waitForChange(timeout: Self.timeout)
    }

    /// The behaviour the monitor exists for. Practically every editor, and
    /// `git`, saves by writing a temporary file and renaming it over the
    /// target — which unlinks the inode the monitor has open. A monitor that
    /// does not re-arm reports this once and is deaf from then on.
    @Test("An atomic replacement is noticed")
    func atomicReplacementIsNoticed() async throws {
        let file = try TemporaryFile(contents: "one")
        let counter = ChangeCounter()
        let monitor = FileChangeMonitor(url: file.url) { counter.increment() }
        defer { monitor.stop() }

        try await settle()
        try "two".write(to: file.url, atomically: true, encoding: .utf8)

        try await counter.waitForChange(timeout: Self.timeout)
    }

    /// And it must keep working afterwards — the failure this guards against
    /// only shows up on the *second* save, which is exactly the kind of thing
    /// a single-shot test misses.
    @Test("It keeps watching after an atomic replacement")
    func watchingSurvivesRepeatedAtomicReplacement() async throws {
        let file = try TemporaryFile(contents: "one")
        let counter = ChangeCounter()
        let monitor = FileChangeMonitor(url: file.url) { counter.increment() }
        defer { monitor.stop() }

        try await settle()
        for revision in ["two", "three", "four"] {
            let before = counter.value
            try revision.write(to: file.url, atomically: true, encoding: .utf8)
            try await counter.waitForChange(above: before, timeout: Self.timeout)
        }
    }

    @Test("A stopped monitor says nothing")
    func stoppedMonitorIsSilent() async throws {
        let file = try TemporaryFile(contents: "one")
        let counter = ChangeCounter()
        let monitor = FileChangeMonitor(url: file.url) { counter.increment() }

        try await settle()
        monitor.stop()
        try await settle()
        let before = counter.value

        try "two".write(to: file.url, atomically: true, encoding: .utf8)
        try await settle()
        try await settle()

        #expect(counter.value == before)
    }

    // MARK: - The watcher

    @Test("Another app's edit with a clean editor becomes a pending reload")
    func externalEditBecomesPendingReload() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        try await settle()
        try "one, revised".write(to: file.url, atomically: true, encoding: .utf8)

        try await waitFor(timeout: Self.timeout) {
            watcher.state == .reloadPending(text: "one, revised")
        }
    }

    @Test("Another app's edit on top of unsaved edits is a conflict")
    func externalEditOnDirtyEditorConflicts() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        watcher.noteEditorText("one, mine")
        try await settle()
        try "one, theirs".write(to: file.url, atomically: true, encoding: .utf8)

        try await waitFor(timeout: Self.timeout) {
            watcher.state == .conflict(text: "one, theirs")
        }
    }

    /// The editor autosaves every 1.5 seconds. If this were not silent the
    /// banner would be on screen permanently while somebody typed.
    @Test("The editor's own save raises nothing")
    func ownSaveRaisesNothing() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        try await settle()
        watcher.noteSaved("one, typed")
        try "one, typed".write(to: file.url, atomically: true, encoding: .utf8)

        try await settle()
        try await settle()
        #expect(watcher.state == .idle)
    }

    /// A save the watcher was never told about — `File ▸ Save` goes through
    /// `NSDocument` and never calls `noteSaved`. It has to be recognised by
    /// the file matching the screen, or every manual save would raise a
    /// banner.
    @Test("A save the watcher was not told about still raises nothing")
    func untrackedOwnSaveRaisesNothing() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        try await settle()
        watcher.noteEditorText("one, typed")
        try "one, typed".write(to: file.url, atomically: true, encoding: .utf8)

        try await settle()
        try await settle()
        #expect(watcher.state == .idle)
    }

    @Test("Keeping mine clears the conflict and stops re-reporting it")
    func keepingMineResolvesTheConflict() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        watcher.noteEditorText("mine")
        try await settle()
        try "theirs".write(to: file.url, atomically: true, encoding: .utf8)
        try await waitFor(timeout: Self.timeout) { watcher.state.isConflicted }

        watcher.resolveByKeepingMine()
        #expect(watcher.state == .idle)

        // The same file contents must not come back as news a moment later.
        try await settle()
        try await settle()
        #expect(watcher.state == .idle)
    }

    @Test("Reloading a conflict hands back the file's text")
    func reloadingAConflictReturnsDiskText() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        watcher.noteEditorText("mine")
        try await settle()
        try "theirs".write(to: file.url, atomically: true, encoding: .utf8)
        try await waitFor(timeout: Self.timeout) { watcher.state.isConflicted }

        #expect(watcher.resolveByReloading() == "theirs")
        #expect(watcher.state == .updated)
    }

    /// The manual command has to work even when no file-system event ever
    /// arrived — a network volume, a missed event, somebody who simply wants
    /// to be sure.
    @Test("Reloading on demand picks up a change no event reported")
    func manualReloadWorksWithoutAnEvent() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        // Never started on this URL, so no monitor is running for it.
        watcher.start(url: file.url, text: "one")
        watcher.stop()

        try "changed underneath".write(
            to: file.url,
            atomically: true,
            encoding: .utf8
        )
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        #expect(watcher.reloadFromDisk() == "changed underneath")
    }

    @Test("Reloading on demand with nothing to say returns nothing")
    func manualReloadWithNoChangeReturnsNil() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        #expect(watcher.reloadFromDisk() == nil)
    }

    /// An unsaved, never-titled document has no file to watch, and asking for
    /// one must not crash or invent a change.
    @Test("A document with no file on disk is simply idle")
    func documentWithoutFileIsIdle() async throws {
        let watcher = ExternalChangeWatcher()
        watcher.start(url: nil, text: "# ")
        defer { watcher.stop() }

        #expect(watcher.state == .idle)
        #expect(watcher.reloadFromDisk() == nil)
    }

    /// Reading a file mid-write can fail or yield half a document. Staying
    /// quiet is the required behaviour: the rename that follows raises its own
    /// event, and this runs again on a whole file.
    @Test("A file that vanishes raises no false change")
    func vanishedFileRaisesNothing() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        try await settle()
        try FileManager.default.removeItem(at: file.url)

        try await settle()
        try await settle()
        #expect(watcher.state == .idle)
    }

    // MARK: - Catching up without an event

    /// The iOS case, and the reason ``ExternalChangeWatcher/recheck()``
    /// exists. An app suspended in the background is not listening, so a write
    /// that happened while it was away produced no event for anybody. Coming
    /// back to the foreground is the moment to look again.
    @Test("Rechecking finds a change that arrived while nobody was listening")
    func recheckFindsAChangeWithNoEvent() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        watcher.stop()

        // Written with no monitor running, so no callback can have fired.
        try "two, while the app was away".write(
            to: file.url,
            atomically: true,
            encoding: .utf8
        )

        // `start` on the same URL is deliberately a no-op after `stop` cleared
        // it, so this stands for the app coming back with the watcher already
        // pointed at the file and simply not having heard anything.
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }
        watcher.noteEditorText("one")
        watcher.recheck()

        #expect(watcher.state == .reloadPending(text: "two, while the app was away"))
    }

    @Test("Rechecking an unchanged file says nothing")
    func recheckOnAnUnchangedFileIsQuiet() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }

        watcher.recheck()
        #expect(watcher.state == .idle)
    }

    @Test("Rechecking with unsaved edits asks rather than overwrites")
    func recheckWithUnsavedEditsConflicts() async throws {
        let file = try TemporaryFile(contents: "one")
        let watcher = ExternalChangeWatcher()
        watcher.start(url: file.url, text: "one")
        watcher.stop()

        try "theirs".write(to: file.url, atomically: true, encoding: .utf8)

        watcher.start(url: file.url, text: "one")
        defer { watcher.stop() }
        watcher.noteEditorText("mine, unsaved")
        watcher.recheck()

        #expect(watcher.state == .conflict(text: "theirs"))
    }

    @Test("Rechecking a document with no file is harmless")
    func recheckWithoutAFileIsHarmless() async throws {
        let watcher = ExternalChangeWatcher()
        watcher.start(url: nil, text: "unsaved")
        defer { watcher.stop() }

        watcher.recheck()
        #expect(watcher.state == .idle)
    }

    // MARK: - Helpers

    /// One monitor debounce interval, with room to spare.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
    }

    private func waitFor(
        timeout: TimeInterval,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(condition(), "timed out")
    }
}

/// A file in a directory of its own, removed when the test ends.
private struct TemporaryFile {
    let url: URL
    private let directory: URL

    init(contents: String) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mde-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("document.md")
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Counts callbacks from whichever queue delivers them.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func waitForChange(above: Int = 0, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if value > above { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(value > above, "no change was reported within \(timeout)s")
    }
}
