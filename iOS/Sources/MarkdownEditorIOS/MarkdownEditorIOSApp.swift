import MarkdownEditorUI
import SwiftUI
import UIKit

/// The iOS app.
///
/// `DocumentGroup` is doing a lot of work here. It gives the document browser,
/// the Files integration, iCloud Drive, the rename and duplicate affordances,
/// and — the part that matters most — the same save lifecycle the macOS app
/// gets, including writing through a file coordinator and prompting on close.
/// None of that is worth reimplementing, and the document type it opens,
/// `MarkdownDocument`, is the identical shared type the Mac uses.
@main
struct MarkdownEditorIOSApp: App {
    @StateObject private var theme = EditorThemeStore()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentEditorView(
                document: file.$document,
                documentURL: file.fileURL
            )
            .environmentObject(theme)
            .preferredColorScheme(theme.theme.mode == .dark ? .dark : .light)
            .tint(Color(platformColor: theme.theme.accentColor))
            .background(
                WindowInterfaceStyle(
                    style: theme.theme.mode == .dark ? .dark : .light
                )
            )
        }
    }
}

/// Pushes the chosen appearance onto the window itself.
///
/// `preferredColorScheme` only reaches SwiftUI's own content. In a
/// `DocumentGroup` the navigation bar, its title, and the status bar belong to
/// UIKit and keep following the device, so choosing a dark theme on a light
/// phone left the document dark and the title dark-on-light-glass — close to
/// unreadable. Overriding the window covers the browser chrome too.
private struct WindowInterfaceStyle: UIViewRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let style = style
        DispatchQueue.main.async {
            view.window?.overrideUserInterfaceStyle = style
        }
    }
}

/// Where the chosen theme lives.
///
/// One store for the whole app rather than per document, matching macOS, where
/// the theme is an application preference rather than a document property.
@MainActor
final class EditorThemeStore: ObservableObject {
    @Published var theme: EditorColorTheme {
        didSet {
            guard theme != oldValue else { return }
            let defaults = UserDefaults.standard
            defaults.set(
                theme.color.rawValue,
                forKey: EditorThemeColor.storageKey
            )
            defaults.set(
                theme.mode.rawValue,
                forKey: EditorAppearanceMode.storageKey
            )
        }
    }

    init() {
        // The keys come from the shared package rather than being spelled out
        // here, so that a Mac and an iPhone agree on what a stored theme means.
        let defaults = UserDefaults.standard
        let color = defaults.string(forKey: EditorThemeColor.storageKey)
            .flatMap(EditorThemeColor.init(rawValue:)) ?? .blue
        let mode = defaults.string(forKey: EditorAppearanceMode.storageKey)
            .flatMap(EditorAppearanceMode.init(rawValue:))
            ?? .systemDefault
        theme = EditorColorTheme(color: color, mode: mode)
    }
}
