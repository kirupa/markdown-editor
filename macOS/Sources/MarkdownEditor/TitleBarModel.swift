import AppKit
import MarkdownEditorCore
import SwiftUI

/// What the title bar says about the draft, kept a beat behind the typing:
/// how long it is, and — for one never saved — what it is called.
///
/// Counting is one pass over the draft: 1.4 ms on the 21,500-word document
/// the typing measurements use. That is nothing once, and too much to add to
/// every keystroke on exactly the drafts where typing is already slowest, so
/// the count waits for a quarter of a second without an edit. Nobody reads a
/// word count mid-word, and the title is read in the same pass for the same
/// reason.
@MainActor
final class TitleBarModel: ObservableObject {
    private static let delay: TimeInterval = 0.25

    @Published private(set) var summary = ""

    /// The draft's title as the name it would be saved under —
    /// `DocumentTitle.draftName` — or `nil` when it has none.
    @Published private(set) var draftName: String?

    private var text = ""
    private var selection: NSRange?
    private var generation = 0

    /// Whether the text has changed since its title was last read. A new
    /// selection changes the count and never the title.
    private var titleIsStale = false

    /// The draft as it now stands. `immediately` for a document that has just
    /// opened, whose length is wanted on its first frame rather than a beat
    /// into it.
    func noteText(_ text: String, immediately: Bool = false) {
        self.text = text
        titleIsStale = true
        if immediately {
            recount()
        } else {
            scheduleRecount()
        }
    }

    /// Where the selection is, in the draft's own characters.
    func noteSelection(_ selection: NSRange) {
        let selection = selection.length > 0 ? selection : nil
        // The caret moving with nothing selected changes nothing the title bar
        // says, and arrow keys should not schedule work.
        guard selection != self.selection else {
            return
        }
        self.selection = selection
        scheduleRecount()
    }

    private func scheduleRecount() {
        generation += 1
        let scheduledGeneration = generation
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.delay
        ) { [weak self] in
            guard let self, self.generation == scheduledGeneration else {
                return
            }
            self.recount()
        }
    }

    private func recount() {
        generation += 1
        let summary = DocumentLength(text: text, selection: selection).summary()
        // Only a different number redraws the title bar.
        if summary != self.summary {
            self.summary = summary
        }
        if titleIsStale {
            titleIsStale = false
            let name = DocumentTitle.draftName(of: text)
            if name != draftName {
                draftName = name
            }
        }
    }
}

/// Shows a `TitleBarModel` in the window's title bar.
///
/// A modifier of its own so that a new count redraws this and nothing else:
/// the editor's view is rebuilt on every keystroke already and does not need
/// another reason.
struct TitleBar: ViewModifier {
    @ObservedObject var model: TitleBarModel

    func body(content: Content) -> some View {
        content
            .navigationSubtitle(model.summary)
            .background(DraftNameTarget(name: model.draftName))
    }
}

/// The bridge to the window's document. Draws nothing.
private struct DraftNameTarget: NSViewRepresentable {
    let name: String?

    func makeCoordinator() -> DraftNamer { DraftNamer() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowWatchingView()
        view.namer = context.coordinator
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.name = name
        context.coordinator.window = nsView.window
        context.coordinator.apply()
    }

    /// A view whose only job is to notice it has a window, which may arrive
    /// after the first update.
    final class WindowWatchingView: NSView {
        weak var namer: DraftNamer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            namer?.window = window
            namer?.apply()
        }
    }
}

/// Names a draft that has never been saved after the title its writer typed,
/// in place of the one macOS would make up — so the title bar shows it and
/// Save proposes it, letter case and all. See `DocumentTitle` for what macOS
/// 27.2 proposed instead.
///
/// `NSDocument.displayName` is the one name both read, and setting it is what
/// stops the system's suggestion: measured on macOS 27.2, a draft named this
/// way was never renamed again, through further edits and autosaves, and Save
/// As replaced the name with the file's as it does for any document. A name
/// the system sets for itself does not count: a draft reopened after the app
/// quit came back under the title it had been given, and its first autosave
/// renamed it "Speed and Latency Notes" anyway.
@MainActor
final class DraftNamer {
    weak var window: NSWindow?
    var name: String?

    private enum Claim {
        /// Not yet seen with its document.
        case unseen

        /// First seen under a name that is not the system's placeholder —
        /// "Untitled", "Untitled 2" — and so is not obviously this one's to
        /// replace. A duplicate arrives named "… copy" on purpose, so that
        /// saving it cannot overwrite its original, and taking its title would
        /// propose exactly the original's name. A draft reopened after a quit
        /// arrives under whatever it was called; when that is its own title,
        /// this named it last time, and does again.
        case unclaimed(String?)

        /// This names the document, and gives it `placeholder` back when its
        /// title goes.
        case naming(placeholder: String)

        /// The document was renamed by someone else — the writer, from the
        /// title bar — and the name is theirs to keep.
        case released
    }

    private var claim = Claim.unseen

    /// The name this last gave the document, so it is renamed only when the
    /// title changes and given back its placeholder only if this took it.
    private var given: String?

    func apply() {
        guard let window,
              let document = window.windowController?.document as? NSDocument,
              // A saved document is named by its file.
              document.fileURL == nil
        else { return }
        let current = document.displayName
        if case .unseen = claim {
            if let current, current.hasPrefix(document.defaultDraftName()) {
                claim = .naming(placeholder: current)
            } else {
                claim = .unclaimed(current)
            }
        }
        switch claim {
        case .unseen, .released:
            return
        case .unclaimed(let reopened):
            guard let name, name == reopened else { return }
            claim = .naming(placeholder: document.defaultDraftName())
            given = name
            // The same name again, set this time by the app rather than by
            // the system reopening it, which is what keeps the suggestion
            // away.
            rename(document, to: name)
        case .naming(let placeholder):
            guard current == (given ?? placeholder) else {
                claim = .released
                return
            }
            if let name {
                guard name != given else { return }
                given = name
                rename(document, to: name)
            } else if given != nil {
                given = nil
                // The placeholder by name rather than `nil`, which asks for a
                // fresh untitled name: on macOS 27.2 that came back as
                // "Untitled -1".
                rename(document, to: placeholder)
            }
        }
    }

    private func rename(_ document: NSDocument, to name: String) {
        document.displayName = name
        for controller in document.windowControllers {
            controller.synchronizeWindowTitleWithDocumentName()
        }
    }
}
