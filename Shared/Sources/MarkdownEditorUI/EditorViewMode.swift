import Foundation

/// How the document is shown: rendered, as Markdown source, or both.
///
/// Shared because the three modes and their SF Symbols are the same product
/// decision on every platform — only the layout that presents them differs.
public enum EditorViewMode: String, CaseIterable, Identifiable {
    case rich = "Rich Text"
    case source = "Markdown"
    case split = "Split"

    public var id: Self {
        self
    }

    public var systemImage: String {
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
