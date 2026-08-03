import AppKit
import SwiftUI

/// Offers to make this build the default application for Markdown files, and
/// reports when it already is.
///
/// The check is re-run whenever the app becomes active, because the setting can
/// be changed from Finder's Get Info panel while the app is running.
struct DefaultMarkdownHandlerButton: View {
    @State private var isDefault = DefaultMarkdownHandler.isCurrentApp

    var body: some View {
        Button(
            isDefault
                ? "Default Markdown Application"
                : "Make Default Markdown Application"
        ) {
            makeDefault()
        }
        .disabled(isDefault)
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            isDefault = DefaultMarkdownHandler.isCurrentApp
        }
    }

    private func makeDefault() {
        Task {
            do {
                try await DefaultMarkdownHandler.makeCurrentAppDefault()
            } catch {
                NSApp.presentError(error)
            }
            isDefault = DefaultMarkdownHandler.isCurrentApp
        }
    }
}
