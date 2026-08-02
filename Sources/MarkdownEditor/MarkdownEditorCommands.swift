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
    @FocusedValue(\.editorColorThemeSelection)
    private var colorThemeSelection

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                session?.chooseExplorerFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(session == nil)
        }

        CommandMenu("Markdown") {
            Menu("Editor View") {
                ForEach(EditorViewMode.allCases) { mode in
                    Button {
                        session?.setViewMode(mode)
                    } label: {
                        if session?.viewMode == mode {
                            Label(mode.rawValue, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue)
                        }
                    }
                }
            }
            .disabled(session == nil)

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

            Button("Cycle Editor View") {
                session?.cycleViewMode()
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
            .disabled(session == nil)

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
        }
    }
}
