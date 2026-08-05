import MarkdownEditorCore
import MarkdownEditorUI
import SwiftUI

/// One button on the formatting bar.
struct FormattingAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let run: (String, NSRange) -> MarkdownEditResult
}

/// The formatting bar's contents.
///
/// Deliberately the same set the Mac toolbar offers and the web build's
/// palette offers, in the same order, because they are the same product. Every
/// entry calls straight into `MarkdownFormatting`.
enum FormattingActions {
    static let inline: [FormattingAction] = [
        FormattingAction(
            id: "bold", title: "Bold", systemImage: "bold"
        ) { text, selection in
            MarkdownFormatting.toggleInline(
                .bold, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "italic", title: "Italic", systemImage: "italic"
        ) { text, selection in
            MarkdownFormatting.toggleInline(
                .italic, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "strikethrough",
            title: "Strikethrough",
            systemImage: "strikethrough"
        ) { text, selection in
            MarkdownFormatting.toggleInline(
                .strikethrough, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "underline", title: "Underline", systemImage: "underline"
        ) { text, selection in
            MarkdownFormatting.toggleInline(
                .underline, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "code",
            title: "Inline Code",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ) { text, selection in
            MarkdownFormatting.toggleInline(
                .inlineCode, in: text, selection: selection
            )
        },
    ]

    static let headings: [FormattingAction] = (1...3).map { level in
        FormattingAction(
            id: "heading\(level)",
            title: "Heading \(level)",
            systemImage: "\(level).square"
        ) { text, selection in
            MarkdownFormatting.applyHeading(
                level: level, in: text, selection: selection
            )
        }
    } + [
        FormattingAction(
            id: "body", title: "Body", systemImage: "textformat"
        ) { text, selection in
            MarkdownFormatting.applyHeading(
                level: 0, in: text, selection: selection
            )
        }
    ]

    static let blocks: [FormattingAction] = [
        FormattingAction(
            id: "bulleted", title: "Bulleted List", systemImage: "list.bullet"
        ) { text, selection in
            MarkdownFormatting.toggleList(
                .bulleted, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "numbered", title: "Numbered List", systemImage: "list.number"
        ) { text, selection in
            MarkdownFormatting.toggleList(
                .numbered, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "task", title: "Task List", systemImage: "checklist"
        ) { text, selection in
            MarkdownFormatting.toggleList(
                .task, in: text, selection: selection
            )
        },
        FormattingAction(
            id: "quote", title: "Quote", systemImage: "text.quote"
        ) { text, selection in
            MarkdownFormatting.toggleQuote(in: text, selection: selection)
        },
        FormattingAction(
            id: "codeBlock", title: "Code Block", systemImage: "curlybraces"
        ) { text, selection in
            MarkdownFormatting.wrapCodeBlock(in: text, selection: selection)
        },
        FormattingAction(
            id: "rule", title: "Divider", systemImage: "minus"
        ) { text, selection in
            MarkdownFormatting.insertHorizontalRule(
                in: text, selection: selection
            )
        },
    ]

    static var all: [FormattingAction] {
        inline + headings + blocks
    }
}

/// A single scrollable row of formatting buttons.
///
/// It scrolls rather than wrapping or truncating because the set is the same
/// on a phone as on an iPad, and hiding half of it behind an overflow menu on
/// the smaller screen would make the smaller screen the worse editor.
struct MarkdownFormattingBar: View {
    @Binding var text: String
    @ObservedObject var controller: EditorController
    let theme: EditorColorTheme
    let onInsertLink: () -> Void
    let onInsertImage: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                group(FormattingActions.headings)
                divider
                group(FormattingActions.inline)
                divider
                group(FormattingActions.blocks)
                divider
                Button(action: onInsertLink) {
                    Label("Insert Link", systemImage: "link")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .frame(width: 40, height: 36)
                .accessibilityLabel("Insert Link")
                Button(action: onInsertImage) {
                    Label("Insert Image", systemImage: "photo")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .frame(width: 40, height: 36)
                .accessibilityLabel("Insert Image")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 40)
        .background(Color(platformColor: theme.sidebarBackgroundColor))
        .foregroundStyle(Color(platformColor: theme.primaryTextColor))
    }

    private var divider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 4)
    }

    private func group(_ actions: [FormattingAction]) -> some View {
        ForEach(actions) { action in
            Button {
                controller.apply(action.run, to: $text)
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 36)
            .accessibilityLabel(action.title)
        }
    }
}
