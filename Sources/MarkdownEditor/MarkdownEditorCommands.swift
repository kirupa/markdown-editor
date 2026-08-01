import SwiftUI

private struct MarkdownEditorSessionKey: FocusedValueKey {
    typealias Value = MarkdownEditorSession
}

extension FocusedValues {
    var markdownEditorSession: MarkdownEditorSession? {
        get { self[MarkdownEditorSessionKey.self] }
        set { self[MarkdownEditorSessionKey.self] = newValue }
    }
}

struct MarkdownEditorCommands: Commands {
    @FocusedValue(\.markdownEditorSession)
    private var session

    var body: some Commands {
        CommandMenu("Markdown") {
            Button(
                session?.viewMode == .rich
                    ? "Show Markdown Source"
                    : "Show Rich Text"
            ) {
                guard let session else {
                    return
                }
                session.setViewMode(
                    session.viewMode == .rich ? .source : .rich
                )
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
            Button("Inline Code") {
                session?.toggleInline(.inlineCode)
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
            Button("Code Block") {
                session?.insertCodeBlock()
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
