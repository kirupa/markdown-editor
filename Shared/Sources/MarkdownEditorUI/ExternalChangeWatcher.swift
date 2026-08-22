import Foundation
import MarkdownEditorCore
import SwiftUI

/// What the editor should be showing about the file underneath it.
///
/// A value rather than a set of flags so that the impossible combinations —
/// "reload pending *and* conflicted", "conflicted with nothing to conflict
/// with" — cannot be written down.
public enum ExternalChangeState: Equatable, Sendable {
    /// The file matches what the editor last saw. Nothing to say.
    case idle

    /// The file changed and nothing on screen would be lost by adopting it.
    /// The view applies `text`, then calls ``ExternalChangeWatcher/acknowledgeReload()``.
    case reloadPending(text: String)

    /// The file changed and there are unsaved edits on screen. Both hold work,
    /// so this waits for a person. Autosave is held off for as long as it does.
    case conflict(text: String)

    /// An external revision was just adopted. Purely to say so.
    case updated

    public var isConflicted: Bool {
        if case .conflict = self { return true }
        return false
    }
}

/// Notices that another app has written the open document, and says what to do.
///
/// Three parts, deliberately separate so that only the smallest one needs a
/// real file to test:
///
///   - ``FileChangeMonitor`` says *the file was touched*
///   - this reads it
///   - ``ExternalDocumentChange`` says *whether that is news*
///
/// The editor writes the file itself, every 1.5 seconds, so the hard part is
/// not noticing changes — it is not crying wolf about the app's own. That is
/// what `lastKnownDiskText` is for, and why every path that writes the file is
/// expected to call ``noteSaved(_:)``. It is a courtesy rather than a
/// requirement: a save that forgets to is still recognised, one beat later,
/// by the file matching the screen.
@MainActor
public final class ExternalChangeWatcher: ObservableObject {
    @Published public private(set) var state: ExternalChangeState = .idle

    /// The last text known to be in the file — whatever this app most recently
    /// read out of it or wrote into it.
    private var lastKnownDiskText: String
    private var editorText: String
    private var url: URL?
    private var monitor: FileChangeMonitor?

    /// How long the "updated" note stays up before clearing itself.
    private static let noticeDuration: TimeInterval = 4
    private var noticeGeneration = 0

    public init() {
        lastKnownDiskText = ""
        editorText = ""
    }

    /// Points the watcher at a document. Safe to call repeatedly; it only does
    /// work when the file or the text has actually changed identity, because
    /// SwiftUI calls the places this is called from far more often than the
    /// document changes.
    public func start(url: URL?, text: String) {
        let standardized = url?.standardizedFileURL
        editorText = text

        guard standardized != self.url else { return }

        self.url = standardized
        lastKnownDiskText = text
        clearNotice()
        state = .idle
        monitor?.stop()

        guard let standardized else {
            monitor = nil
            return
        }

        monitor = FileChangeMonitor(url: standardized) { [weak self] in
            // Already hopped to the main queue by the monitor.
            MainActor.assumeIsolated {
                self?.fileChanged()
            }
        }
    }

    public func stop() {
        monitor?.stop()
        monitor = nil
        url = nil
        clearNotice()
        state = .idle
    }

    /// The text on screen changed. Keeps the conflict test honest while
    /// somebody is typing into a document that is already conflicted.
    public func noteEditorText(_ text: String) {
        editorText = text
    }

    /// This app wrote the file. Recorded so the write is not reported back as
    /// somebody else's.
    public func noteSaved(_ text: String) {
        lastKnownDiskText = text
        editorText = text
        if state.isConflicted { return }
        clearNotice()
        if case .updated = state { return }
        state = .idle
    }

    /// This app wrote the file with whatever is on screen. For save paths that
    /// hand the text to `NSDocument` rather than holding it themselves.
    public func noteSaved() {
        noteSaved(editorText)
    }

    /// The view has applied the text from ``ExternalChangeState/reloadPending(text:)``
    /// or accepted the file's version of a conflict.
    public func acknowledgeReload() {
        guard case let .reloadPending(text) = state else { return }
        adopt(text)
    }

    /// Take the file's version and discard the unsaved edits on screen.
    /// Returns the text the view should apply, or `nil` if nothing is pending.
    public func resolveByReloading() -> String? {
        switch state {
        case let .conflict(text), let .reloadPending(text):
            adopt(text)
            return text
        case .idle, .updated:
            return nil
        }
    }

    /// Keep what is on screen. The file's version stops being news — it has
    /// been seen and rejected — so autosave resumes and overwrites it.
    public func resolveByKeepingMine() {
        guard case let .conflict(text) = state else { return }
        lastKnownDiskText = text
        state = .idle
    }

    /// Re-reads the file on demand, for a Reload command that a person invoked
    /// rather than the file system. Returns the text to apply, if it differs.
    public func reloadFromDisk() -> String? {
        if let text = resolveByReloading() {
            return text
        }
        guard let text = readDisk() else { return nil }
        guard text != editorText else {
            lastKnownDiskText = text
            return nil
        }
        adopt(text)
        return text
    }

    public func dismissNotice() {
        if case .updated = state {
            state = .idle
        }
    }

    /// Re-examines the file without waiting for an event.
    ///
    /// A watcher only hears about writes made while it was listening, and an
    /// app that has been suspended in the background was not. Coming back to
    /// the foreground is exactly when the file is most likely to have moved on
    /// — iCloud, Files, another device — so the check is repeated then.
    public func recheck() {
        fileChanged()
    }

    private func adopt(_ text: String) {
        lastKnownDiskText = text
        editorText = text
        state = .updated
        showNoticeThenClear()
    }

    private func fileChanged() {
        guard url != nil, let diskText = readDisk() else { return }

        switch ExternalDocumentChange.detect(
            editorText: editorText,
            lastKnownDiskText: lastKnownDiskText,
            diskText: diskText
        ) {
        case .none:
            // Still worth recording: this is how a save performed without
            // calling `noteSaved` stops being a surprise on the next event.
            lastKnownDiskText = diskText
        case .reloadable:
            clearNotice()
            state = .reloadPending(text: diskText)
        case .conflict:
            clearNotice()
            state = .conflict(text: diskText)
        }
    }

    private func readDisk() -> String? {
        guard let url else { return nil }
        // A file being replaced can be unreadable for a moment, and a document
        // that is briefly half-written is not worth an error in front of
        // somebody. Staying quiet is right here: the monitor will report the
        // rename that follows, and this will run again on a whole file.
        guard let data = try? Data(contentsOf: url),
            let decoded = try? MarkdownTextCodec.decodeUTF8(data)
        else {
            return nil
        }
        return decoded.text
    }

    private func showNoticeThenClear() {
        noticeGeneration += 1
        let generation = noticeGeneration
        Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000)
            )
            guard let self, self.noticeGeneration == generation else { return }
            if case .updated = self.state {
                self.state = .idle
            }
        }
    }

    private func clearNotice() {
        noticeGeneration += 1
    }
}
