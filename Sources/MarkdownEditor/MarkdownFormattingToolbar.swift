import SwiftUI

struct MarkdownFormattingToolbar: ToolbarContent {
    @ObservedObject var session: MarkdownEditorSession

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker(
                "Editor View",
                selection: Binding(
                    get: { session.viewMode },
                    set: { session.setViewMode($0) }
                )
            ) {
                ForEach(EditorViewMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help("Switch between rendered editing and Markdown source")
        }

        ToolbarItem {
            Menu {
                Button("Paragraph") {
                    session.applyHeading(level: 0)
                }
                Divider()
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") {
                        session.applyHeading(level: level)
                    }
                }
            } label: {
                Label("Text Style", systemImage: "textformat.size")
            }
            .help("Paragraph and heading style")
        }

        ToolbarItem {
            ControlGroup {
                formattingButton(
                    "Bold",
                    systemImage: "bold"
                ) {
                    session.toggleInline(.bold)
                }
                formattingButton(
                    "Italic",
                    systemImage: "italic"
                ) {
                    session.toggleInline(.italic)
                }
                formattingButton(
                    "Underline",
                    systemImage: "underline"
                ) {
                    session.toggleInline(.underline)
                }
                formattingButton(
                    "Strikethrough",
                    systemImage: "strikethrough"
                ) {
                    session.toggleInline(.strikethrough)
                }
            }
            .labelStyle(.iconOnly)
        }

        ToolbarItem {
            Menu {
                Button {
                    session.toggleInline(.inlineCode)
                } label: {
                    Label(
                        "Inline Code (Single Line)",
                        systemImage: "curlybraces"
                    )
                }
                Button {
                    session.insertFencedCodeBlock()
                } label: {
                    Label(
                        "Fenced Code Block (Multi-Line)",
                        systemImage: "terminal"
                    )
                }
            } label: {
                Label(
                    "Code",
                    systemImage: "chevron.left.forwardslash.chevron.right"
                )
            }
            .help("Insert single-line or multi-line code")
        }

        ToolbarItem {
            ControlGroup {
                formattingButton(
                    "Bulleted List",
                    systemImage: "list.bullet"
                ) {
                    session.toggleList(.bulleted)
                }
                formattingButton(
                    "Numbered List",
                    systemImage: "list.number"
                ) {
                    session.toggleList(.numbered)
                }
                formattingButton(
                    "Task List",
                    systemImage: "checklist"
                ) {
                    session.toggleList(.task)
                }
                formattingButton(
                    "Quote",
                    systemImage: "text.quote"
                ) {
                    session.toggleQuote()
                }
            }
            .labelStyle(.iconOnly)
        }

        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                formattingButton(
                    "Link",
                    systemImage: "link"
                ) {
                    session.chooseLink()
                }
                formattingButton(
                    "Horizontal Rule",
                    systemImage: "minus"
                ) {
                    session.insertHorizontalRule()
                }
                formattingButton(
                    "Add Image",
                    systemImage: "photo.badge.plus"
                ) {
                    session.chooseAndInsertImage()
                }
            }
            .labelStyle(.iconOnly)
        }
    }

    private func formattingButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(title)
    }
}
