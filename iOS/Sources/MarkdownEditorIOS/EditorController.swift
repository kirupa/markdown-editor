import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI
import UIKit

/// Everything the editor screen needs to know that is not the document itself.
///
/// The document text stays in `MarkdownDocument`, owned by `DocumentGroup`, so
/// that undo, autosave, and the close prompt keep working the way the system
/// expects. This holds the things around it: which pane is showing, where the
/// caret is in the *source*, and any error worth putting in front of someone.
@MainActor
final class EditorController: ObservableObject {
    @Published var viewMode: EditorViewMode = EditorController.storedViewMode {
        didSet {
            guard viewMode != oldValue else { return }
            UserDefaults.standard.set(
                viewMode.rawValue,
                forKey: EditorViewMode.storageKey
            )
        }
    }
    @Published var selection = NSRange(location: 0, length: 0)
    @Published var errorMessage: String?
    @Published var isShowingThemePicker = false

    /// Bumped whenever the source is changed by something other than the text
    /// view that is currently being typed in — a formatting command, or the
    /// other pane in split view. The editors watch it so they know to re-read
    /// the text instead of assuming they are already showing it.
    @Published private(set) var externalRevision = 0

    /// Set while a formatting command is rewriting the source, so the text
    /// views can tell an edit they caused from one they did not.
    private(set) var isApplyingCommand = false

    /// The last mode chosen on this device, or Rich Text the first time.
    private static var storedViewMode: EditorViewMode {
        UserDefaults.standard.string(forKey: EditorViewMode.storageKey)
            .flatMap(EditorViewMode.init(rawValue:)) ?? .rich
    }

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    /// Runs a formatting command over the current source and selection.
    ///
    /// The command itself lives in `MarkdownFormatting`, which is the same
    /// code the Mac app and — by way of a hand port checked against it — the
    /// web app run. Nothing about *what* bold means is decided here.
    func apply(
        _ command: (String, NSRange) -> MarkdownEditResult,
        to text: Binding<String>
    ) {
        let result = command(text.wrappedValue, selection)
        guard result.text != text.wrappedValue || result.selection != selection
        else {
            return
        }
        isApplyingCommand = true
        text.wrappedValue = result.text
        selection = result.selection
        externalRevision += 1
        isApplyingCommand = false
    }

    /// Puts literal text in at the caret, replacing any selection.
    ///
    /// Used for the one insertion that is not a formatting command: an image
    /// reference, which `MarkdownImageImporter` has already built.
    func insert(_ fragment: String, into text: Binding<String>) {
        apply(
            { source, selection in
                MarkdownTextInsertion.insert(
                    fragment, in: source, selection: selection
                )
            },
            to: text
        )
    }

    /// Records a change made by one of the text views.
    ///
    /// In split view the *other* view still has to be told, which is what the
    /// revision counter is for; the view that made the edit ignores it.
    func recordEdit(from source: EditorSurface) {
        lastEditingSurface = source
        externalRevision += 1
    }

    private(set) var lastEditingSurface: EditorSurface?
}

/// Which of the two panes something came from.
enum EditorSurface: Hashable {
    case rich
    case source
}
