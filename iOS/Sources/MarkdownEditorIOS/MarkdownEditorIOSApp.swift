import MarkdownEditorUI
import SwiftUI

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
        }
    }
}

/// Where the chosen theme lives.
///
/// One store for the whole app rather than per document, matching macOS, where
/// the theme is an application preference rather than a document property.
@MainActor
final class EditorThemeStore: ObservableObject {
    private static let colorKey = "EditorThemeColor"
    private static let modeKey = "EditorThemeMode"

    @Published var theme: EditorColorTheme {
        didSet {
            guard theme != oldValue else { return }
            let defaults = UserDefaults.standard
            defaults.set(theme.color.rawValue, forKey: Self.colorKey)
            defaults.set(theme.mode.rawValue, forKey: Self.modeKey)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let color = defaults.string(forKey: Self.colorKey)
            .flatMap(EditorThemeColor.init(rawValue:)) ?? .blue
        let mode = defaults.string(forKey: Self.modeKey)
            .flatMap(EditorAppearanceMode.init(rawValue:)) ?? .light
        theme = EditorColorTheme(color: color, mode: mode)
    }
}
