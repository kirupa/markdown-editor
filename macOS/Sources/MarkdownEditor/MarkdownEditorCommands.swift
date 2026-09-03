import MarkdownEditorUI
import SwiftUI

private struct MarkdownEditorSessionKey: FocusedValueKey {
    typealias Value = MarkdownEditorSession
}

private struct EditorColorThemeSelectionKey: FocusedValueKey {
    typealias Value = Binding<EditorColorTheme>
}

extension FocusedValues {
    var markdownEditorSession: MarkdownEditorSession? {
        get { self[MarkdownEditorSessionKey.self] }
        set { self[MarkdownEditorSessionKey.self] = newValue }
    }

    var editorColorThemeSelection: Binding<EditorColorTheme>? {
        get { self[EditorColorThemeSelectionKey.self] }
        set { self[EditorColorThemeSelectionKey.self] = newValue }
    }
}

struct MarkdownEditorCommands: Commands {
    @FocusedValue(\.markdownEditorSession)
    private var session
    @FocusedValue(\.runCritique)
    private var runCritique: (() -> Void)?

    @FocusedValue(\.editorColorThemeSelection)
    private var colorThemeSelection

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Divider()
            DefaultMarkdownHandlerButton()
        }

        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                session?.chooseExplorerFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(session == nil)

            Button("Reload from Disk") {
                session?.reloadFromDisk()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(session?.fileURL == nil)
        }

        CommandGroup(after: .sidebar) {
            Button(
                session?.isExplorerVisible == true
                    ? "Hide File Explorer"
                    : "Show File Explorer"
            ) {
                session?.toggleExplorer()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            .disabled(session == nil)

            Divider()
        }

        CommandGroup(before: .windowList) {
            Button("Welcome to Markdown Editor") {
                WelcomeWindowController.shared.show()
            }
            Divider()
        }

        CommandMenu("Markdown") {
            Button("AI Assisted Critique") { runCritique?() }
                .keyboardShortcut("c", modifiers: [.control, .command])
                .disabled(runCritique == nil)

            Divider()

            Menu("Theme Color") {
                ForEach(EditorThemeColor.allCases) { themeColor in
                    Button {
                        colorThemeSelection?.wrappedValue.color = themeColor
                    } label: {
                        if colorThemeSelection?.wrappedValue.color
                            == themeColor {
                            Label(themeColor.title, systemImage: "checkmark")
                        } else {
                            Text(themeColor.title)
                        }
                    }
                }
                .disabled(colorThemeSelection == nil)
            }

            Menu("Background") {
                ForEach(EditorAppearanceMode.allCases) { mode in
                    Button {
                        colorThemeSelection?.wrappedValue.mode = mode
                    } label: {
                        if colorThemeSelection?.wrappedValue.mode == mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
                .disabled(colorThemeSelection == nil)
            }

            Divider()

            Button("Bold") {
                session?.toggleInline(.bold)
            }
            .keyboardShortcut("b")
            Button("Italic") {
                session?.toggleInline(.italic)
            }
            .keyboardShortcut("i")
            Button("Underline") {
                session?.toggleInline(.underline)
            }
            .keyboardShortcut("u")
            Button("Strikethrough") {
                session?.toggleInline(.strikethrough)
            }

            Menu("Code") {
                Button("Inline Code (Single Line)") {
                    session?.toggleInline(.inlineCode)
                }
                Button("Fenced Code Block (Multi-Line)") {
                    session?.insertFencedCodeBlock()
                }
            }

            Menu("Heading") {
                Button("Paragraph") {
                    session?.applyHeading(level: 0)
                }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        session?.applyHeading(level: level)
                    }
                }
            }

            Divider()

            Button("Bulleted List") {
                session?.toggleList(.bulleted)
            }
            Button("Numbered List") {
                session?.toggleList(.numbered)
            }
            Button("Task List") {
                session?.toggleList(.task)
            }
            Button("Quote") {
                session?.toggleQuote()
            }
            Button("Horizontal Rule") {
                session?.insertHorizontalRule()
            }
        }

        CommandMenu("Insert") {
            Button("Link…") {
                session?.chooseLink()
            }
            .keyboardShortcut("k")
            Button("Image…") {
                session?.chooseAndInsertImage()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(session == nil)
            Button("Image Size…") {
                session?.chooseImageSize()
            }
            .keyboardShortcut("i", modifiers: [.command, .option, .shift])
            .disabled(session == nil)
        }
    }
}


/// The focused document's critique command.
///
/// Routed through the focus system rather than a notification. A notification
/// reaches every open document at once, and each one then has to work out
/// whether it was the intended target — which cannot be done reliably for a
/// document that has never been saved, because it has no URL to be recognised
/// by. Two unsaved windows would both run a critique, and both would spend
/// credits.
struct CritiqueActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var runCritique: CritiqueActionKey.Value? {
        get { self[CritiqueActionKey.self] }
        set { self[CritiqueActionKey.self] = newValue }
    }
}
