import AppKit
import MarkdownEditorCore

enum EditorViewMode: String, CaseIterable, Identifiable {
    case rich = "Rich Text"
    case source = "Markdown"

    var id: Self {
        self
    }

    var systemImage: String {
        switch self {
        case .rich:
            "doc.richtext"
        case .source:
            "chevron.left.forwardslash.chevron.right"
        }
    }
}

@MainActor
protocol MarkdownEditingSurface: AnyObject {
    var sourceText: String { get }
    var selectedSourceRange: NSRange { get }
    var hostingWindow: NSWindow? { get }

    func apply(_ result: MarkdownEditResult, actionName: String)
    func restore(_ result: MarkdownEditResult)
    func commitPendingComposition()
    func setSourceSelection(_ selection: NSRange)
    func focus()
}
