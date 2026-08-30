import AppKit
import MarkdownEditorUI
import SwiftUI

struct MarkdownEditorView: View {
    @Binding private var document: MarkdownDocument
    @StateObject private var session: MarkdownEditorSession
    @StateObject private var autosaveController =
        DocumentAutosaveController()
    @State private var explorerWidth = Layout.defaultExplorerWidth
    @State private var dragStartExplorerWidth: CGFloat?
    @State private var previewWidth = Layout.defaultPreviewWidth
    @Binding private var themeColorRawValue: String
    @Binding private var appearanceModeRawValue: String
    private let fileURL: URL?

    init(
        document: Binding<MarkdownDocument>,
        fileURL: URL?,
        themeColorRawValue: Binding<String>,
        appearanceModeRawValue: Binding<String>
    ) {
        _document = document
        _session = StateObject(
            wrappedValue: MarkdownEditorSession(
                fileURL: fileURL,
                initialText: document.wrappedValue.text
            )
        )
        _themeColorRawValue = themeColorRawValue
        _appearanceModeRawValue = appearanceModeRawValue
        self.fileURL = fileURL
    }

    private var colorTheme: EditorColorTheme {
        EditorColorTheme(
            color: EditorThemeColor(rawValue: themeColorRawValue) ?? .blue,
            mode: EditorAppearanceMode(rawValue: appearanceModeRawValue)
                ?? .systemDefault
        )
    }

    private var colorThemeSelection: Binding<EditorColorTheme> {
        Binding(
            get: { colorTheme },
            set: { newTheme in
                themeColorRawValue = newTheme.color.rawValue
                appearanceModeRawValue = newTheme.mode.rawValue
            }
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let visibleExplorerWidth = clampedExplorerWidth(
                explorerWidth,
                totalWidth: geometry.size.width
            )

            // X-18: the explorer floats over the document rather than taking
            // part in the row. Opening it must not move the text by a pixel,
            // which also means the reading measure centers on the window
            // rather than on whatever the explorer leaves over.
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ExternalChangeBanner(
                        state: session.externalChange.state,
                        colorTheme: colorTheme,
                        onReload: { session.reloadFromDisk() },
                        onKeepMine: {
                            session.keepMyVersion()
                            autosaveController.scheduleSave(for: fileURL)
                        }
                    )

                    Group {
                        switch session.viewMode {
                        case .rich:
                            ResizableRichTextPreview(
                                text: $document.text,
                                documentURL: fileURL,
                                session: session,
                                colorTheme: colorTheme,
                                preferredWidth: $previewWidth,
                                minimumWidth: Layout.minimumPreviewWidth
                            )
                        case .source:
                            SourceTextEditor(
                                text: $document.text,
                                session: session,
                                colorTheme: colorTheme
                            )
                        case .split:
                            HSplitView {
                                ResizableRichTextPreview(
                                    text: $document.text,
                                    documentURL: fileURL,
                                    session: session,
                                    colorTheme: colorTheme,
                                    preferredWidth: $previewWidth,
                                    minimumWidth: Layout.minimumSplitPreviewWidth
                                )
                                .frame(
                                    minWidth: Layout.minimumSplitPaneWidth,
                                    maxWidth: .infinity
                                )

                                SourceTextEditor(
                                    text: $document.text,
                                    session: session,
                                    colorTheme: colorTheme
                                )
                                .frame(
                                    minWidth: Layout.minimumSplitPaneWidth,
                                    maxWidth: .infinity
                                )
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if session.isExplorerVisible {
                    HStack(spacing: 0) {
                        FileExplorerSidebar(
                            session: session,
                            colorTheme: colorTheme
                        )
                            .frame(width: visibleExplorerWidth)

                        WidthGripper(
                            colorTheme: colorTheme,
                            displayedWidth: visibleExplorerWidth,
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
                                adjustExplorerWidth(
                                    direction,
                                    totalWidth: geometry.size.width,
                                    visibleExplorerWidth: visibleExplorerWidth
                                )
                            },
                            helpText: """
                                Drag to resize the file explorer; double-click \
                                to reset its width
                                """,
                            accessibilityLabel: "File explorer width"
                        )
                    }
                    .frame(maxHeight: .infinity)
                    // Opaque, or the document would read through the tree.
                    .background(colorTheme.sidebarBackground)
                    .shadow(
                        color: .black.opacity(0.18),
                        radius: 12,
                        x: 2,
                        y: 0
                    )
                    .transition(.move(edge: .leading))
                    .zIndex(1)
                }
            }
        }
        .frame(minWidth: Layout.minimumWindowWidth, minHeight: 520)
        .background(colorTheme.canvasBackground)
        .preferredColorScheme(colorTheme.colorScheme)
        .focusedSceneValue(\.markdownEditorSession, session)
        .focusedSceneValue(
            \.editorColorThemeSelection,
            colorThemeSelection
        )
        .toolbar {
            MarkdownFormattingToolbar(
                session: session,
                colorTheme: colorThemeSelection
            )
        }
        .onAppear {
            if let fileURL {
                RecentDocumentsModel.shared.record(fileURL)
            }
            session.startWatchingFile(text: document.text)
            autosaveController.onSave = { [session] in
                session.externalChange.noteSaved()
            }
        }
        .onChange(of: fileURL) { newFileURL in
            autosaveController.cancelPendingSave()
            session.fileURL = newFileURL
            if let newFileURL {
                RecentDocumentsModel.shared.record(newFileURL)
            }
            // Save As and Finder renames both land here, and the old file is
            // no longer the one being edited.
            session.startWatchingFile(text: document.text)
        }
        .onChange(of: document.text) { newText in
            session.externalChange.noteEditorText(newText)
            // Writing during an unresolved conflict would overwrite the other
            // app's version seconds after pointing it out.
            guard !session.isSavingSuspended else {
                autosaveController.cancelPendingSave()
                return
            }
            autosaveController.scheduleSave(for: fileURL)
        }
        .onChange(of: session.externalChange.state) { state in
            guard case .reloadPending(let text) = state else {
                return
            }
            // Nothing of this person's is at stake, so asking would be a
            // question with one sensible answer. Take it and say so.
            session.applyExternalText(text, actionName: "Refresh")
            session.externalChange.acknowledgeReload()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willResignActiveNotification
            )
        ) { _ in
            guard !session.isSavingSuspended else {
                return
            }
            autosaveController.saveNow(for: fileURL)
        }
        .onDisappear {
            autosaveController.cancelPendingSave()
            session.stopWatchingFile()
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

    private func adjustExplorerWidth(
        _ direction: AccessibilityAdjustmentDirection,
        totalWidth: CGFloat,
        visibleExplorerWidth: CGFloat
    ) {
        let explorerAdjustment: CGFloat
        switch direction {
        case .increment:
            explorerAdjustment = Layout.keyboardResizeStep
        case .decrement:
            explorerAdjustment = -Layout.keyboardResizeStep
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
        EditorPaneGeometry.explorerWidth(
            proposedWidth,
            totalWidth: totalWidth,
            minimum: Layout.minimumExplorerWidth,
            maximum: Layout.maximumExplorerWidth
        )
    }
}

private struct ResizableRichTextPreview: View {
    @Binding var text: String
    let documentURL: URL?
    let session: MarkdownEditorSession
    let colorTheme: EditorColorTheme
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
                // Y-8: centered on the window. The gripper hangs outside the
                // measure as an overlay so that reaching for it cannot itself
                // shift the text it resizes.
                Spacer(minLength: 0)

                RichTextEditor(
                    text: $text,
                    documentURL: documentURL,
                    session: session,
                    colorTheme: colorTheme,
                    layoutWidth: visibleWidth
                )
                .frame(width: visibleWidth)
                .overlay(alignment: .trailing) {
                    WidthGripper(
                        colorTheme: colorTheme,
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
                            Drag to resize the Rich Text document; double-click \
                            to reset its width
                            """,
                        accessibilityLabel: "Rich Text document width"
                    )
                    .offset(x: Layout.gripperWidth)
                }

                Spacer(minLength: 0)
            }
        }
        .background(colorTheme.canvasBackground)
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
        EditorPaneGeometry.measureWidth(
            proposedWidth,
            totalWidth: totalWidth,
            minimum: minimumWidth,
            maximum: Layout.maximumPreviewWidth,
            handleWidth: Layout.gripperWidth
        )
    }
}

private struct WidthGripper: View {
    let colorTheme: EditorColorTheme
    let displayedWidth: CGFloat
    let dragGesture: AnyGesture<DragGesture.Value>
    let onReset: () -> Void
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void
    let helpText: String
    let accessibilityLabel: String

    @State private var isHovering = false

    var body: some View {
        // Y-9: quiet until it is wanted. A permanent rule with three dots on
        // it is furniture the document has to compete with, and this one is
        // findable by hovering the edge whether or not it is drawn.
        ZStack {
            Color.accentColor
                .opacity(isHovering ? 0.08 : 0)
            Rectangle()
                .fill(Color(nsColor: colorTheme.separatorColor))
                .frame(width: 1)
                .opacity(isHovering ? 1 : 0.4)
            VStack(spacing: 3) {
                ForEach(0..<3) { _ in
                    Circle()
                        .fill(Color(nsColor: colorTheme.secondaryTextColor))
                        .frame(width: 3, height: 3)
                }
            }
            .opacity(isHovering ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
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
    // X-18: the explorer floats, so it no longer needs a column of its own for
    // the window to be usable. The window only has to fit a document.
    static let minimumWindowWidth = defaultDocumentWidth
}
