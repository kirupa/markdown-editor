import AppKit
import MarkdownEditorCore
import SwiftUI

struct FileExplorerOutlineView: NSViewRepresentable {
    @ObservedObject var model: FileExplorerModel
    let currentFileURL: URL?
    let colorTheme: EditorColorTheme
    let onOpen: (FileTreeEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            colorTheme: colorTheme,
            onOpen: onOpen
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let outlineView = NSOutlineView()
        let column = NSTableColumn(identifier: .fileExplorerColumn)
        column.resizingMask = .autoresizingMask

        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.style = .sourceList
        outlineView.indentationPerLevel = 14
        outlineView.autoresizesOutlineColumn = true
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(
            Coordinator.activateSelectedItem(_:)
        )
        outlineView.setAccessibilityLabel("File explorer")

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        context.coordinator.outlineView = outlineView
        context.coordinator.updateTheme(colorTheme, in: scrollView)
        context.coordinator.reload(
            rootURL: model.rootURL,
            generation: model.generation,
            currentFileURL: currentFileURL
        )
        return scrollView
    }

    func updateNSView(
        _ scrollView: NSScrollView,
        context: Context
    ) {
        context.coordinator.model = model
        context.coordinator.onOpen = onOpen
        context.coordinator.updateTheme(colorTheme, in: scrollView)
        context.coordinator.reload(
            rootURL: model.rootURL,
            generation: model.generation,
            currentFileURL: currentFileURL
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource,
        NSOutlineViewDelegate
    {
        var model: FileExplorerModel
        var colorTheme: EditorColorTheme
        var onOpen: (FileTreeEntry) -> Void
        weak var outlineView: NSOutlineView?

        private var rootNode: FileTreeNode?
        private var loadedRootURL: URL?
        private var loadedGeneration = -1
        private var revealedFileURL: URL?
        private var selectedRowIndexes = IndexSet()

        init(
            model: FileExplorerModel,
            colorTheme: EditorColorTheme,
            onOpen: @escaping (FileTreeEntry) -> Void
        ) {
            self.model = model
            self.colorTheme = colorTheme
            self.onOpen = onOpen
        }

        func updateTheme(
            _ colorTheme: EditorColorTheme,
            in scrollView: NSScrollView
        ) {
            let changed = self.colorTheme != colorTheme
            self.colorTheme = colorTheme
            guard let outlineView else {
                return
            }
            colorTheme.apply(to: outlineView, in: scrollView)
            guard changed else {
                return
            }
            refreshVisibleRows(in: outlineView)
        }

        func reload(
            rootURL: URL?,
            generation: Int,
            currentFileURL: URL?
        ) {
            let standardizedRoot = rootURL?.standardizedFileURL
            if loadedRootURL != standardizedRoot
                || loadedGeneration != generation
            {
                loadedRootURL = standardizedRoot
                loadedGeneration = generation
                revealedFileURL = nil
                rootNode = standardizedRoot.map {
                    FileTreeNode(
                        entry: FileTreeEntry(
                            url: $0,
                            name: $0.lastPathComponent,
                            isDirectory: true,
                            isSymbolicLink: false,
                            isPackage: false
                        )
                    )
                }
                outlineView?.reloadData()
            }

            let standardizedFile = currentFileURL?.standardizedFileURL
            if revealedFileURL != standardizedFile {
                revealedFileURL = standardizedFile
                reveal(standardizedFile)
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            node(for: item)?.children(using: model).count ?? 0
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            guard let child = node(for: item)?
                .children(using: model)[safe: index]
            else {
                preconditionFailure("File explorer requested an invalid child")
            }
            return child
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            isItemExpandable item: Any
        ) -> Bool {
            (item as? FileTreeNode)?.entry.isExpandable == true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let node = item as? FileTreeNode else {
                return nil
            }

            let cell = outlineView.makeView(
                withIdentifier: .fileExplorerCell,
                owner: self
            ) as? FileExplorerCellView
                ?? FileExplorerCellView()
            let row = outlineView.row(forItem: item)
            cell.configure(
                with: node.entry,
                colorTheme: colorTheme,
                isSelected: row >= 0 && outlineView.isRowSelected(row)
            )
            return cell
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            rowViewForItem item: Any
        ) -> NSTableRowView? {
            let rowView = FileExplorerRowView()
            rowView.colorTheme = colorTheme
            return rowView
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else {
                return
            }
            let currentSelection = outlineView.selectedRowIndexes
            let changedRows = selectedRowIndexes.symmetricDifference(
                currentSelection
            )
            selectedRowIndexes = currentSelection
            refreshRows(changedRows, in: outlineView)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            shouldSelectItem item: Any
        ) -> Bool {
            item is FileTreeNode
        }

        @objc
        func activateSelectedItem(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0,
                let node = sender.item(atRow: sender.clickedRow)
                    as? FileTreeNode
            else {
                return
            }

            if node.entry.isExpandable {
                if sender.isItemExpanded(node) {
                    sender.collapseItem(node)
                } else {
                    sender.expandItem(node)
                }
            } else {
                onOpen(node.entry)
            }
        }

        private func node(for item: Any?) -> FileTreeNode? {
            if let item {
                return item as? FileTreeNode
            }
            return rootNode
        }

        private func refreshVisibleRows(in outlineView: NSOutlineView) {
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            guard visibleRows.location != NSNotFound,
                visibleRows.length > 0
            else {
                return
            }
            refreshRows(
                IndexSet(
                    integersIn: visibleRows.location..<NSMaxRange(visibleRows)
                ),
                in: outlineView
            )
        }

        private func refreshRows(
            _ rows: IndexSet,
            in outlineView: NSOutlineView
        ) {
            for row in rows where row < outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row)
                    as? FileTreeNode
                else {
                    continue
                }
                if let cell = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? FileExplorerCellView {
                    cell.configure(
                        with: node.entry,
                        colorTheme: colorTheme,
                        isSelected: outlineView.isRowSelected(row)
                    )
                }
                if let rowView = outlineView.rowView(
                    atRow: row,
                    makeIfNecessary: false
                ) as? FileExplorerRowView {
                    rowView.colorTheme = colorTheme
                    rowView.needsDisplay = true
                }
            }
        }

        private func reveal(_ fileURL: URL?) {
            guard let rootNode, let fileURL, let outlineView else {
                return
            }
            let rootComponents = rootNode.entry.url.pathComponents
            let fileComponents = fileURL.pathComponents
            guard fileComponents.starts(with: rootComponents) else {
                return
            }

            var parent = rootNode
            let relativeComponents = fileComponents.dropFirst(
                rootComponents.count
            )
            for (index, component) in relativeComponents.enumerated() {
                guard let child = parent.children(using: model)
                    .first(where: { $0.entry.name == component })
                else {
                    return
                }
                if index == relativeComponents.count - 1 {
                    let row = outlineView.row(forItem: child)
                    if row >= 0 {
                        outlineView.selectRowIndexes(
                            IndexSet(integer: row),
                            byExtendingSelection: false
                        )
                        outlineView.scrollRowToVisible(row)
                    }
                } else {
                    outlineView.expandItem(child)
                    parent = child
                }
            }
        }
    }
}

@MainActor
private final class FileTreeNode: NSObject {
    let entry: FileTreeEntry
    private var loadedChildren: [FileTreeNode]?

    init(entry: FileTreeEntry) {
        self.entry = entry
    }

    func children(using model: FileExplorerModel) -> [FileTreeNode] {
        guard entry.isExpandable else {
            return []
        }
        if let loadedChildren {
            return loadedChildren
        }
        let children = model.children(of: entry.url).map(FileTreeNode.init)
        loadedChildren = children
        return children
    }
}

@MainActor
private final class FileExplorerRowView: NSTableRowView {
    var colorTheme = EditorColorTheme.systemDefault

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else {
            return
        }
        colorTheme.selectionBackgroundColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 2, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }
}

@MainActor
private final class FileExplorerCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        identifier = .fileExplorerCell
        imageView = iconView
        textField = nameField
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingMiddle
        addSubview(iconView)
        addSubview(nameField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor,
                constant: 6
            ),
            nameField.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -4
            ),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        with entry: FileTreeEntry,
        colorTheme: EditorColorTheme,
        isSelected: Bool
    ) {
        nameField.stringValue = entry.name
        if isSelected {
            nameField.textColor = colorTheme.selectionTextColor
        } else {
            nameField.textColor = entry.isDirectory
                || FileTreeScanner.isMarkdownDocument(entry.url)
                ? colorTheme.primaryTextColor
                : colorTheme.secondaryTextColor
        }
        iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        iconView.imageScaling = .scaleProportionallyDown
        toolTip = entry.url.path
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let fileExplorerCell = Self("FileExplorerCell")
    static let fileExplorerColumn = Self("FileExplorerColumn")
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
