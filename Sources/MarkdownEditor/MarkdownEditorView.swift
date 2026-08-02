import AppKit
import SwiftUI

struct MarkdownEditorView: View {
    @Binding private var document: MarkdownDocument
    @StateObject private var session: MarkdownEditorSession
    @State private var explorerWidth = Layout.defaultExplorerWidth
    @State private var dragStartExplorerWidth: CGFloat?
    @State private var previewWidth = Layout.defaultPreviewWidth
    private let fileURL: URL?

    init(document: Binding<MarkdownDocument>, fileURL: URL?) {
        _document = document
        _session = StateObject(
            wrappedValue: MarkdownEditorSession(fileURL: fileURL)
        )
        self.fileURL = fileURL
    }

    var body: some View {
        GeometryReader { geometry in
            let visibleExplorerWidth = clampedExplorerWidth(
                explorerWidth,
                totalWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                FileExplorerSidebar(session: session)
                    .frame(width: visibleExplorerWidth)

                WidthGripper(
                    displayedWidth: geometry.size.width
                        - visibleExplorerWidth
                        - Layout.gripperWidth,
                    dragGesture: resizeGesture(
                        totalWidth: geometry.size.width,
                        visibleExplorerWidth: visibleExplorerWidth
                    ),
                    onReset: {
                        explorerWidth = clampedExplorerWidth(
                            Layout.defaultExplorerWidth,
                            totalWidth: geometry.size.width
                        )
                    },
                    onAdjust: { direction in
                        adjustDocumentWidth(
                            direction,
                            totalWidth: geometry.size.width,
                            visibleExplorerWidth: visibleExplorerWidth
                        )
                    },
                    helpText: """
                        Drag to resize the editor pane; double-click to reset \
                        the split
                        """,
                    accessibilityLabel: "Editor pane width"
                )

                Group {
                    switch session.viewMode {
                    case .rich:
                        ResizableRichTextPreview(
                            text: $document.text,
                            documentURL: fileURL,
                            session: session,
                            preferredWidth: $previewWidth,
                            minimumWidth: Layout.minimumPreviewWidth
                        )
                    case .source:
                        SourceTextEditor(
                            text: $document.text,
                            session: session
                        )
                    case .split:
                        HSplitView {
                            ResizableRichTextPreview(
                                text: $document.text,
                                documentURL: fileURL,
                                session: session,
                                preferredWidth: $previewWidth,
                                minimumWidth: Layout.minimumSplitPreviewWidth
                            )
                            .frame(
                                minWidth: Layout.minimumSplitPaneWidth,
                                maxWidth: .infinity
                            )

                            SourceTextEditor(
                                text: $document.text,
                                session: session
                            )
                            .frame(
                                minWidth: Layout.minimumSplitPaneWidth,
                                maxWidth: .infinity
                            )
                        }
                    }
                }
                .frame(
                    minWidth: Layout.minimumDocumentWidth,
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .frame(minWidth: Layout.minimumWindowWidth, minHeight: 520)
        .focusedSceneValue(\.markdownEditorSession, session)
        .toolbar {
            MarkdownFormattingToolbar(session: session)
        }
        .onChange(of: fileURL) { newFileURL in
            session.fileURL = newFileURL
        }
    }

    private func resizeGesture(
        totalWidth: CGFloat,
        visibleExplorerWidth: CGFloat
    ) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartExplorerWidth == nil {
                        dragStartExplorerWidth = visibleExplorerWidth
                    }
                    let startWidth = dragStartExplorerWidth
                        ?? visibleExplorerWidth
                    explorerWidth = clampedExplorerWidth(
                        startWidth + value.translation.width,
                        totalWidth: totalWidth
                    )
                }
                .onEnded { _ in
                    dragStartExplorerWidth = nil
                }
        )
    }

    private func adjustDocumentWidth(
        _ direction: AccessibilityAdjustmentDirection,
        totalWidth: CGFloat,
        visibleExplorerWidth: CGFloat
    ) {
        let explorerAdjustment: CGFloat
        switch direction {
        case .increment:
            explorerAdjustment = -Layout.keyboardResizeStep
        case .decrement:
            explorerAdjustment = Layout.keyboardResizeStep
        @unknown default:
            return
        }

        explorerWidth = clampedExplorerWidth(
            visibleExplorerWidth + explorerAdjustment,
            totalWidth: totalWidth
        )
    }

    private func clampedExplorerWidth(
        _ proposedWidth: CGFloat,
        totalWidth: CGFloat
    ) -> CGFloat {
        let maximumWidth = max(
            Layout.minimumExplorerWidth,
            min(
                Layout.maximumExplorerWidth,
                totalWidth - Layout.minimumDocumentWidth
                    - Layout.gripperWidth
            )
        )
        return min(
            max(proposedWidth, Layout.minimumExplorerWidth),
            maximumWidth
        )
    }
}

private struct ResizableRichTextPreview: View {
    @Binding var text: String
    let documentURL: URL?
    let session: MarkdownEditorSession
    @Binding var preferredWidth: CGFloat
    let minimumWidth: CGFloat

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let visibleWidth = clampedWidth(
                preferredWidth,
                totalWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                RichTextEditor(
                    text: $text,
                    documentURL: documentURL,
                    session: session,
                    layoutWidth: visibleWidth
                )
                .frame(width: visibleWidth)

                WidthGripper(
                    displayedWidth: visibleWidth,
                    dragGesture: resizeGesture(
                        totalWidth: geometry.size.width,
                        visibleWidth: visibleWidth
                    ),
                    onReset: {
                        preferredWidth = clampedWidth(
                            Layout.defaultPreviewWidth,
                            totalWidth: geometry.size.width
                        )
                    },
                    onAdjust: { direction in
                        adjustWidth(
                            direction,
                            totalWidth: geometry.size.width,
                            visibleWidth: visibleWidth
                        )
                    },
                    helpText: """
                        Drag to resize the Rich Text document; double-click to \
                        reset its width
                        """,
                    accessibilityLabel: "Rich Text document width"
                )

                Spacer(minLength: 0)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func resizeGesture(
        totalWidth: CGFloat,
        visibleWidth: CGFloat
    ) -> AnyGesture<DragGesture.Value> {
        AnyGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = visibleWidth
                    }
                    preferredWidth = clampedWidth(
                        (dragStartWidth ?? visibleWidth)
                            + value.translation.width,
                        totalWidth: totalWidth
                    )
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }

    private func adjustWidth(
        _ direction: AccessibilityAdjustmentDirection,
        totalWidth: CGFloat,
        visibleWidth: CGFloat
    ) {
        let adjustment: CGFloat
        switch direction {
        case .increment:
            adjustment = Layout.keyboardResizeStep
        case .decrement:
            adjustment = -Layout.keyboardResizeStep
        @unknown default:
            return
        }

        preferredWidth = clampedWidth(
            visibleWidth + adjustment,
            totalWidth: totalWidth
        )
    }

    private func clampedWidth(
        _ proposedWidth: CGFloat,
        totalWidth: CGFloat
    ) -> CGFloat {
        let availableWidth = max(
            minimumWidth,
            totalWidth - Layout.gripperWidth
        )
        let maximumWidth = min(
            Layout.maximumPreviewWidth,
            availableWidth
        )
        return min(
            max(proposedWidth, minimumWidth),
            maximumWidth
        )
    }
}

private struct WidthGripper: View {
    let displayedWidth: CGFloat
    let dragGesture: AnyGesture<DragGesture.Value>
    let onReset: () -> Void
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void
    let helpText: String
    let accessibilityLabel: String

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.accentColor
                .opacity(isHovering ? 0.08 : 0)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
            VStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Circle()
                        .fill(.secondary)
                        .frame(width: 3, height: 3)
                }
            }
        }
        .frame(width: Layout.gripperWidth)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onTapGesture(count: 2, perform: onReset)
        .onHover { hovering in
            isHovering = hovering
            (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
        }
        .onDisappear {
            if isHovering {
                NSCursor.arrow.set()
            }
        }
        .help(helpText)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue("\(Int(displayedWidth.rounded())) points")
        .accessibilityAdjustableAction(onAdjust)
    }
}

private enum Layout {
    static let minimumExplorerWidth: CGFloat = 190
    static let defaultExplorerWidth: CGFloat = 240
    static let maximumExplorerWidth: CGFloat = 420
    static let minimumDocumentWidth: CGFloat = 520
    static let defaultDocumentWidth: CGFloat = 620
    static let minimumPreviewWidth: CGFloat = 360
    static let minimumSplitPreviewWidth: CGFloat = 220
    static let minimumSplitPaneWidth: CGFloat = 240
    static let defaultPreviewWidth: CGFloat = 700
    static let maximumPreviewWidth: CGFloat = 1_100
    static let gripperWidth: CGFloat = 12
    static let keyboardResizeStep: CGFloat = 20
    static let minimumWindowWidth = defaultExplorerWidth
        + defaultDocumentWidth
        + gripperWidth
}
