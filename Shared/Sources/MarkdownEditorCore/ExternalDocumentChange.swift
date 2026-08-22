import Foundation

/// What to do when the file under an open document changes on disk.
///
/// Another app can write the file the editor has open — a `git checkout`, a
/// sync client, a script, the same document open on a second Mac through
/// iCloud Drive. This decides what that means, given three pieces of text and
/// nothing else, so the rule can be read and tested without a file system, a
/// timer, or a window.
///
/// The three texts are the whole problem:
///
///   - `editorText` — what is on screen right now
///   - `lastKnownDiskText` — the text this app last read from, or wrote to,
///     the file. Its job is to recognise the app's own writes.
///   - `diskText` — what the file says now
///
/// `lastKnownDiskText` is what makes this possible at all. The naive test —
/// "does the file differ from the screen?" — calls the app's own autosave an
/// external change every time, because autosave writes a version and the
/// person carries on typing before the write event arrives (see
/// `DocumentAutosaveController`, which writes every 1.5 seconds).
public enum ExternalDocumentChange: Equatable, Sendable {
    /// The file carries no news: it matches what this app last saw, or it now
    /// matches what is on screen. Nothing to tell anybody about.
    case none

    /// The file changed and there is nothing on screen that adopting it would
    /// destroy, because the screen still holds exactly what the file used to
    /// say. Safe to apply without asking.
    case reloadable

    /// The file changed *and* there are unsaved edits on screen. Both versions
    /// contain work, so this one cannot be resolved without being asked, and
    /// until it is, neither side may overwrite the other.
    case conflict

    /// Reads the situation.
    ///
    /// Deliberately total and order-dependent; each branch below rules out a
    /// specific way of being wrong.
    public static func detect(
        editorText: String,
        lastKnownDiskText: String,
        diskText: String
    ) -> ExternalDocumentChange {
        // The common case by a wide margin: the file is exactly what this app
        // last wrote or read. Every autosave lands here, including the ones
        // whose change event arrives after the person has typed several more
        // characters — which is why this is compared against the last known
        // text and not against the screen.
        if diskText == lastKnownDiskText {
            return .none
        }

        // The file changed into precisely what is on screen. Nobody needs
        // telling that their own text has arrived, and this is the branch that
        // makes the whole thing self-correcting: any save this app performs
        // without recording it — File ▸ Save, a revert, a save from code that
        // never heard of this type — is recognised here rather than reported
        // as somebody else's work.
        if diskText == editorText {
            return .none
        }

        // The file changed and the screen did not, so the screen holds no work
        // that is not already in the file's history.
        if editorText == lastKnownDiskText {
            return .reloadable
        }

        // Both moved. Whatever happens next, somebody's writing is at stake.
        return .conflict
    }
}
