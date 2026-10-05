// What does VoiceOver say each control is?
//
// Nothing on screen shows it. An icon button nobody named is read by its
// symbol's own name, and the names SwiftUI gives the symbols this app uses are
// often something else entirely: the formatting bar's quote mark was read as
// "Lyrics", its rule as "Remove", its picture as "Photo With A Plus Badge",
// and its paragraph-style menu as "Change Text Size". Each of those passed
// every other check, because every other check looks at pixels.
//
// So this asks the questions VoiceOver asks — what is each control, and what
// is it called — of the real views, in process. SwiftUI builds its
// accessibility tree only for an assistive app, and saying this process is
// one, with the enhanced-interface switch VoiceOver itself sets, is what makes
// it answer: without it every host reports no children at all. Asked from
// another process instead, through `AXUIElement`, every element came back as
// the application itself while the screen was locked, so that route checks
// nothing on the machine these mostly run on.
//
// Built by Scripts/run-voiceover-checks.sh against the real app sources.

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

/// A control as VoiceOver meets it.
struct Spoken: CustomStringConvertible {
    let role: String
    /// What it is called: the title where it has one, because a menu
    /// button's name lives there, and otherwise its description.
    let name: String
    let value: String
    let hint: String

    var description: String {
        "\(role) \"\(name)\"" + (value.isEmpty ? "" : " = \"\(value)\"")
    }
}

/// The roles VoiceOver stops on as something to press, pick or read.
private let stoppingRoles: Set<String> = [
    "AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox",
    "AXRadioButton", "AXSlider", "AXImage",
]

/// Every control in `content`, in reading order, as its accessibility tree
/// describes it. `whileOpen` runs before the window closes, with a way to
/// press a control by its name; it says whether there was one to press.
@MainActor
func spokenControls(
    in content: some View,
    size: NSSize,
    whileOpen: (_ press: (String) -> Bool) -> Void = { _ in }
) -> [Spoken] {
    let host = NSHostingView(rootView: content)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame, styleMask: [.titled],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.alphaValue = 0
    window.orderBack(nil)
    defer { window.close() }

    settle(for: 1)
    // The first question builds the tree; the answer comes on a later turn
    // of the run loop.
    _ = host.accessibilityChildren()
    settle(for: 0.6)

    // Asked by selector, not `value(forKey:)`: a row of the explorer's outline
    // has no key-value answer for these, and asking that way crashed.
    func ask(_ object: NSObject, _ question: String) -> Any? {
        let selector = NSSelectorFromString(question)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    // A default menu button's title is attributed text, not a string, and
    // read as a string it looked unnamed when it was not.
    func text(_ answer: Any?) -> String {
        if let string = answer as? String { return string }
        if let attributed = answer as? NSAttributedString { return attributed.string }
        if let number = answer as? NSNumber { return number.stringValue }
        return ""
    }

    var found: [Spoken] = []
    var elements: [(name: String, element: NSObject)] = []
    func walk(_ element: Any, depth: Int) {
        guard depth < 60, let object = element as? NSObject else { return }
        let role = text(ask(object, "accessibilityRole"))
        if stoppingRoles.contains(role) {
            let title = text(ask(object, "accessibilityTitle"))
            let label = text(ask(object, "accessibilityLabel"))
            found.append(Spoken(
                role: role,
                name: title.isEmpty ? label : title,
                value: text(ask(object, "accessibilityValue")),
                hint: text(ask(object, "accessibilityHelp"))
            ))
            elements.append((found[found.count - 1].name, object))
        }
        for child in (ask(object, "accessibilityChildren") as? [Any]) ?? [] {
            walk(child, depth: depth + 1)
        }
    }
    walk(host, depth: 0)
    // What was read, for when a check fails and the list in its message is
    // not enough to say why.
    if ProcessInfo.processInfo.environment["MDE_VOICEOVER_DUMP"] != nil {
        for control in found {
            print("       · \(control)" + (control.hint.isEmpty ? "" : " — \(control.hint)"))
        }
    }
    // Pressed as VoiceOver presses, with `accessibilityPerformPress`. The
    // older `accessibilityPerformAction(.press)` reached no SwiftUI control,
    // not even a plain button, so a check made with it fails everything.
    whileOpen { name in
        guard let element = elements.first(where: { $0.name == name })?.element else {
            return false
        }
        _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
        settle(for: 0.3)
        return true
    }
    return found
}

@MainActor
func settle(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

/// The checks every surface gets: everything VoiceOver stops on can be told
/// apart by name, and no picture is stopped on at all.
@MainActor
func checkEverythingIsNamed(_ controls: [Spoken], in surface: String) {
    let unnamed = controls.filter {
        $0.role != "AXImage" && $0.name.trimmingCharacters(in: .whitespaces).isEmpty
    }
    check(
        "every control in \(surface) has a name",
        !controls.isEmpty && unnamed.isEmpty,
        controls.isEmpty
            ? "the tree had no controls in it, so nothing was asked"
            : "unnamed: \(unnamed.map(\.description).joined(separator: ", "))"
    )
    // The pictures here sit beside words that already say what they are, so
    // a picture VoiceOver stops on is the same thing said twice, and in the
    // symbol's words: the rail's sparkles, the explorer's folder, the welcome
    // window's clock and each recent document's page.
    let pictures = controls.filter { $0.role == "AXImage" }
    check(
        "and no picture is stopped on as if it were one",
        pictures.isEmpty,
        "read: \(pictures.map(\.description).joined(separator: ", "))"
    )
}

/// Whether `expected` all appear among `names`, in that order, with anything
/// else between them. A name may come more than once: a stale rail has
/// "Critique again" in its header and its banner both.
func inOrder(_ expected: [String], in names: [String]) -> Bool {
    var remaining = expected[...]
    for name in names where name == remaining.first {
        remaining = remaining.dropFirst()
    }
    return remaining.isEmpty
}

/// The editor with its document in SwiftUI state, as `DocumentGroup` holds it.
struct EditorHost: View {
    @State var document = MarkdownDocument(text: """
        # Field notes on speed

        Caching is important because the cache stores data for later reads.

        """)
    @State private var themeColor = EditorThemeColor.blue.rawValue
    @State private var appearance = EditorAppearanceMode.light.rawValue

    var body: some View {
        MarkdownEditorView(
            document: $document,
            fileURL: nil,
            themeColorRawValue: $themeColor,
            appearanceModeRawValue: $appearance,
            typefaceRawValue: .constant(EditorTypeface.sans.rawValue),
            textScale: .constant(1)
        )
    }
}

/// The theme popover's own binding, as the toolbar holds it, kept where a
/// check can see what pressing one of its controls did.
@MainActor
final class ThemeStore: ObservableObject {
    @Published var theme = EditorColorTheme(color: .blue, mode: .light)
}

struct ThemeHost: View {
    @ObservedObject var store: ThemeStore

    var body: some View {
        ThemePickerPopover(colorTheme: $store.theme, isPresented: .constant(true))
    }
}

@main
@MainActor
enum Harness {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        application.perform(
            NSSelectorFromString("accessibilitySetEnhancedUserInterfaceAttribute:"),
            with: NSNumber(value: true)
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Field notes", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory.deletingLastPathComponent()
            )
        }

        checkTheEditorWindow()
        checkTheRailWithNotes()
        checkTheThemePopover()
        checkTheFileExplorer(in: directory)
        checkTheWelcomeWindow(in: directory)

        print("")
        if failures == 0 {
            print("\(checks)/\(checks) checks passed")
            exit(0)
        }
        print("\(failures) of \(checks) checks failed")
        exit(1)
    }

    static func checkTheEditorWindow() {
        print("The editor window")
        let controls = spokenControls(
            in: EditorHost(), size: NSSize(width: 1_100, height: 620)
        )
        let names = controls.map(\.name)
        checkEverythingIsNamed(controls, in: "the window")

        let bar = [
            "Paragraph Style", "Bold", "Italic", "Underline", "Strikethrough", "Code",
            "Bulleted List", "Numbered List", "Task List", "Quote", "Link",
            "Horizontal Rule", "Add Image",
        ]
        check(
            "the formatting bar is read by what each control does",
            inOrder(bar, in: names),
            "read: \(names.joined(separator: ", "))"
        )
        // What each was read as before it was named, measured against the
        // views as they were, so that one coming back is named in the failure
        // rather than merely missing from a list.
        let symbolNames = [
            "Change Text Size", "Strike Through", "Embed Code", "List",
            "Checklist With Checkmarks", "Lyrics", "Remove",
            "Photo With A Plus Badge", "Edit",
        ]
        let misread = names.filter { name in
            symbolNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        check(
            "and nothing is read by its symbol's name",
            misread.isEmpty,
            "read: \(misread.joined(separator: ", "))"
        )
        check(
            "the rail's controls say what they do",
            inOrder(
                [
                    "Critique settings", "Handwriting for notes", "Close critique",
                    "Edit audience and goal", "Run critique", "Quick pass",
                ],
                in: names
            ),
            "read: \(names.joined(separator: ", "))"
        )
    }

    static func checkTheRailWithNotes() {
        print("")
        print("The rail with notes on it")

        let draft = """
            # Shipping Faster

            Our deploys take forty minutes because every test runs on every change.

            Most teams never measure where that time goes, so they guess.

            Caching the dependency install alone saved us twelve minutes a build.

            """
        let report = CritiqueReport(
            jobRead: "A post for engineers.",
            overall: "Clear, short of evidence.",
            whatWorks: ["The opening number."],
            whatDoesNotWork: ["No sources."],
            findings: [
                CritiqueFinding(
                    severity: .high, category: "Logic", location: "paragraph 1",
                    quote: "every test runs on every change",
                    why: "Every test? Say which.",
                    replacement: "the full suite runs on every change"
                ),
                CritiqueFinding(
                    severity: .medium, category: "Evidence", location: "paragraph 2",
                    quote: "so they guess", why: "Who guesses? Name one."
                ),
                CritiqueFinding(
                    severity: .low, category: "Clarity", location: "paragraph 3",
                    quote: "saved us twelve minutes a build", why: "Of how many?"
                ),
            ]
        )
        let model = CritiqueModel()
        model.applyForChecking(report, for: draft)
        // One answered, so its way back is on the rail; one chosen, so its
        // Apply, Done and Dismiss are.
        model.setResolution(.completed, for: model.items[2].id)
        model.press(model.items[0])

        func rail() -> some View {
            CritiqueSidebar(
                critique: model,
                colorTheme: EditorColorTheme(color: .blue, mode: .light),
                isStale: true,
                onRerun: {}, onRerunChanges: {}, onQuickPass: {},
                replaceText: { _ in nil }
            )
        }
        let size = NSSize(width: 356, height: 1_400)

        let restoreDensity = pinDefault(CritiqueSidebar.compactNotesKey, to: false)
        let full = spokenControls(in: rail(), size: size)
        restoreDensity()
        let names = full.map(\.name)
        checkEverythingIsNamed(full, in: "the rail")
        check(
            "its history, filters and notes say what they do",
            inOrder(
                [
                    "Earlier critiques", "Critique again", "1 high", "1 medium",
                    "Compact notes", "Apply", "Done", "Dismiss",
                    "Put this note back.",
                ],
                in: names
            ),
            "read: \(names.joined(separator: ", "))"
        )
        // `.textCase(.uppercase)` on the chip's words reached past them into
        // the button's own name and hint, so VoiceOver was handed "1 HIGH"
        // and "SHOWS ONLY THESE NOTES": how the chip looks, not what it says.
        let chips = full.filter { $0.name.hasPrefix("1 ") }
        check(
            "a severity filter is spoken in words, not capitals",
            chips.count == 2
                && chips.allSatisfy { $0.name == $0.name.lowercased() }
                && chips.allSatisfy { $0.hint == "Shows only these notes" },
            "read: \(chips.map { "\($0.name) (\($0.hint))" }.joined(separator: ", "))"
        )

        let restoreCompact = pinDefault(CritiqueSidebar.compactNotesKey, to: true)
        let compact = spokenControls(in: rail(), size: size)
        restoreCompact()
        checkEverythingIsNamed(compact, in: "the compact rail")
        check(
            "and its switch says what pressing it does now",
            compact.contains { $0.name == "Show notes in full" },
            "read: \(compact.map(\.name).joined(separator: ", "))"
        )
    }

    static func checkTheThemePopover() {
        print("")
        print("The theme popover")
        let store = ThemeStore()
        func size() -> String { "\(Int((store.theme.textScale * 100).rounded()))%" }
        var pressed: [String] = []
        let controls = spokenControls(
            in: ThemeHost(store: store), size: NSSize(width: 420, height: 700)
        ) { press in
            for name in ["Smaller text", "Larger text", "Larger text"] {
                let before = size()
                pressed.append(press(name) ? "\(name) \(before) → \(size())" : "no \(name)")
            }
        }
        // The size slider's two A's are its value labels, and each is a
        // button: hidden, they were buttons VoiceOver stopped on and read as
        // nothing.
        checkEverythingIsNamed(controls, in: "the popover")
        check(
            "every colour is named as a theme",
            controls.filter { $0.name.hasSuffix(" theme") }.count
                == EditorThemeColor.allCases.count,
            "read: \(controls.map(\.name).joined(separator: ", "))"
        )
        let font = controls.first { $0.role == "AXMenuButton" }
        check(
            "the font menu says it is the font, and which",
            font?.name == "Font" && font?.value == EditorTypeface.sans.title,
            "read: \(font.map(\.description) ?? "no menu")"
        )
        let slider = controls.first { $0.role == "AXSlider" }
        check(
            "the size slider says what it sizes, and by how much",
            slider?.name == "Text size" && slider?.value == "100%",
            "read: \(slider.map(\.description) ?? "no slider")"
        )
        // A click on either A steps the size by 5%, and so does VoiceOver's
        // press. Hidden and set beside the slider as plain pictures, so that
        // VoiceOver would pass over them, they did neither.
        check(
            "the A either side of it says what it does, and does it pressed",
            pressed == [
                "Smaller text 100% → 95%", "Larger text 95% → 100%",
                "Larger text 100% → 105%",
            ],
            "pressed: \(pressed.joined(separator: ", "))"
        )
    }

    static func checkTheFileExplorer(in directory: URL) {
        print("")
        print("The file explorer")
        let theme = EditorColorTheme(color: .blue, mode: .light)
        let size = NSSize(width: 260, height: 600)

        let file = directory.appendingPathComponent("Notes.md")
        try? "# Notes\n".write(to: file, atomically: true, encoding: .utf8)
        let opened = MarkdownEditorSession(fileURL: file, initialText: "# Notes\n")
        let browsing = spokenControls(
            in: FileExplorerSidebar(session: opened, colorTheme: theme), size: size
        )
        checkEverythingIsNamed(browsing, in: "the explorer")
        check(
            "its folder menu and buttons say what they are",
            inOrder(
                ["Field notes", "Refresh Explorer", "Show Current Document Folder"],
                in: browsing.map(\.name)
            ),
            "read: \(browsing.map(\.name).joined(separator: ", "))"
        )

        // A draft never saved has no folder, so the explorer says so instead.
        let unsaved = MarkdownEditorSession(fileURL: nil)
        let empty = spokenControls(
            in: FileExplorerSidebar(session: unsaved, colorTheme: theme), size: size
        )
        checkEverythingIsNamed(empty, in: "the explorer with no folder")
    }

    static func checkTheWelcomeWindow(in directory: URL) {
        print("")
        print("The welcome window")
        // Its own preferences, so the reader's own list of recent documents
        // is neither read nor written.
        let suite = "com.kirupa.markdown-editor.check-voiceover"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "recentDocumentsSeededFromDocumentController")
        let size = NSSize(width: 760, height: 460)
        func welcome() -> some View {
            WelcomeView(
                recentDocuments: RecentDocumentsModel(defaults: defaults),
                onNewDocument: {}, onOpenDocument: {}, onOpenRecent: { _ in }
            )
        }

        defaults.set([String](), forKey: "recentDocumentPaths")
        let first = spokenControls(in: welcome(), size: size)
        checkEverythingIsNamed(first, in: "the welcome window")
        check(
            "its actions say what they do",
            inOrder(
                ["New Document", "Open…", "Show this window at launch"],
                in: first.map(\.name)
            ),
            "read: \(first.map(\.name).joined(separator: ", "))"
        )

        let recent = directory.appendingPathComponent("Draft.md")
        try? "# Draft\n".write(to: recent, atomically: true, encoding: .utf8)
        defaults.set([recent.path], forKey: "recentDocumentPaths")
        let returning = spokenControls(in: welcome(), size: size)
        checkEverythingIsNamed(returning, in: "the welcome window with a recent document")
        check(
            "a recent document is read by its name",
            returning.contains { $0.name == RecentDocumentsCatalog.entries(for: [recent]).first?.name },
            "read: \(returning.map(\.name).joined(separator: ", "))"
        )
    }
}

/// Sets a preference for the length of a check, and returns what puts it back.
func pinDefault(_ key: String, to value: Any) -> () -> Void {
    let stored = UserDefaults.standard.object(forKey: key)
    UserDefaults.standard.set(value, forKey: key)
    return {
        if let stored {
            UserDefaults.standard.set(stored, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
