import SwiftUI

/// The strip that appears when the file has changed underneath the editor.
///
/// Shared, because there is one thing to say and it should be said the same
/// way on a Mac and on an iPad. It is a bar across the top of the document
/// rather than an alert on purpose: an alert would seize the keyboard for
/// something that is very often not urgent, and would have to be dismissed
/// before the person could look at the document it is talking about.
///
/// Two shapes, matching the two situations ``ExternalChangeState`` can be in:
///
///   - **updated** — already applied, so this is a receipt. It clears itself.
///   - **conflict** — nothing has been applied and nothing will be until this
///     is answered, because either answer destroys something.
public struct ExternalChangeBanner: View {
    private let state: ExternalChangeState
    private let colorTheme: EditorColorTheme
    private let onReload: () -> Void
    private let onKeepMine: () -> Void

    public init(
        state: ExternalChangeState,
        colorTheme: EditorColorTheme,
        onReload: @escaping () -> Void,
        onKeepMine: @escaping () -> Void
    ) {
        self.state = state
        self.colorTheme = colorTheme
        self.onReload = onReload
        self.onKeepMine = onKeepMine
    }

    public var body: some View {
        switch state {
        case .idle, .reloadPending:
            EmptyView()
        case .updated:
            bar(
                icon: "arrow.clockwise.circle.fill",
                message: "Updated — this document was changed by another app.",
                isConflict: false
            ) {
                EmptyView()
            }
        case .conflict:
            bar(
                icon: "exclamationmark.triangle.fill",
                message: """
                    This document was changed by another app. Your unsaved \
                    edits are still here.
                    """,
                isConflict: true
            ) {
                HStack(spacing: 8) {
                    Button("Keep Mine", action: onKeepMine)
                        .help(
                            """
                            Keep what is on screen and overwrite the version \
                            on disk
                            """
                        )
                    Button("Reload", action: onReload)
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                        .help(
                            """
                            Discard the unsaved edits here and show the \
                            version on disk
                            """
                        )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func bar<Actions: View>(
        icon: String,
        message: String,
        isConflict: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(
                    isConflict ? Color.orange : Color(platformColor: colorTheme.accentColor)
                )
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(platformColor: colorTheme.separatorColor))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var background: some View {
        ZStack {
            Color(platformColor: colorTheme.editorBackgroundColor)
            (isConflictState ? Color.orange : Color(platformColor: colorTheme.accentColor))
                .opacity(0.12)
        }
    }

    private var isConflictState: Bool {
        state.isConflicted
    }
}
