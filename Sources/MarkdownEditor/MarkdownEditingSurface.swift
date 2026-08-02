import AppKit
import MarkdownEditorCore

enum EditorViewMode: String, CaseIterable, Identifiable {
    case rich = "Rich Text"
    case source = "Markdown"
    case split = "Split"

    var id: Self {
        self
    }

    var systemImage: String {
        switch self {
        case .rich:
            "doc.richtext"
        case .source:
            "chevron.left.forwardslash.chevron.right"
        case .split:
            "rectangle.split.2x1"
        }
    }
}

@MainActor
protocol MarkdownEditingSurface: AnyObject {
    var sourceText: String { get }
    var selectedSourceRange: NSRange { get }
    var hostingWindow: NSWindow? { get }
    var hasFocus: Bool { get }

    func apply(_ result: MarkdownEditResult, actionName: String)
    func restore(_ result: MarkdownEditResult)
    func commitPendingComposition()
    func setSourceSelection(_ selection: NSRange)
    func focus()
}
