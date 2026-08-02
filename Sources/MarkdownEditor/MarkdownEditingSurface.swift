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
    var normalizedScrollPosition: CGFloat { get }

    func apply(_ result: MarkdownEditResult, actionName: String)
    func restore(_ result: MarkdownEditResult)
    func commitPendingComposition()
    func setSourceSelection(_ selection: NSRange)
    func setNormalizedScrollPosition(_ position: CGFloat)
    func focus()
}

@MainActor
final class EditorScrollSynchronizer: NSObject {
    var didScroll: ((CGFloat) -> Void)?

    private weak var scrollView: NSScrollView?
    private var isApplyingPosition = false

    var normalizedPosition: CGFloat {
        guard let scrollView else {
            return 0
        }
        let clipView = scrollView.contentView
        let maximumOffset = max(
            0,
            (scrollView.documentView?.frame.height ?? 0)
                - clipView.bounds.height
        )
        guard maximumOffset > 0 else {
            return 0
        }
        return min(max(clipView.bounds.minY / maximumOffset, 0), 1)
    }

    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView {
            return
        }
        detach()
        self.scrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    func detach() {
        if let contentView = scrollView?.contentView {
            NotificationCenter.default.removeObserver(
                self,
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
        }
        scrollView = nil
    }

    func setNormalizedPosition(_ position: CGFloat) {
        guard let scrollView else {
            return
        }

        isApplyingPosition = true
        defer {
            isApplyingPosition = false
        }
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()

        let clipView = scrollView.contentView
        let maximumOffset = max(
            0,
            (scrollView.documentView?.frame.height ?? 0)
                - clipView.bounds.height
        )
        let targetOffset = min(max(position, 0), 1) * maximumOffset
        guard abs(clipView.bounds.minY - targetOffset) > 0.5 else {
            return
        }

        clipView.scroll(
            to: NSPoint(
                x: clipView.bounds.minX,
                y: targetOffset
            )
        )
        scrollView.reflectScrolledClipView(clipView)
    }

    @objc
    private func boundsDidChange(_ notification: Notification) {
        guard !isApplyingPosition else {
            return
        }
        didScroll?(normalizedPosition)
    }
}
