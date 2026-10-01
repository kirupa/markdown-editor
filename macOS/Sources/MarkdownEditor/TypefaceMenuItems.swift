import MarkdownEditorUI
import SwiftUI

/// Every face on offer, as menu items: grouped, and each name set in itself.
///
/// The one list both the critique's hand menu and Customize Theme ▸ Font show,
/// so the two cannot come to offer different faces or show them differently.
///
/// Each name is set in its own face because the names mean nothing — nobody
/// knows what "Caveat" looks like, and a list of names in one font asks you to
/// guess and then look. Grouped because a flat list of fifteen faces is a
/// wall: the system face first and alone, since it is not a hand and it is the
/// most legible at length, then what came with the app, then what came with
/// the Mac.
struct TypefaceMenuItems: View {
    let selected: EditorTypeface
    let choose: (EditorTypeface) -> Void

    var body: some View {
        choice(.sans)
        Divider()
        Section("Bundled") {
            ForEach(EditorTypeface.available.filter(\.isBundled)) { candidate in
                choice(candidate)
            }
        }
        let system = EditorTypeface.available.filter {
            !$0.isBundled && $0 != .sans
        }
        if !system.isEmpty {
            Section("From your Mac") {
                ForEach(system) { candidate in choice(candidate) }
            }
        }
    }

    private func choice(_ candidate: EditorTypeface) -> some View {
        Button {
            choose(candidate)
        } label: {
            HStack {
                Text(candidate.title)
                    .font(CritiqueTypography.named(
                        candidate, size: CritiqueTypography.bodySize
                    ))
                if candidate == selected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
