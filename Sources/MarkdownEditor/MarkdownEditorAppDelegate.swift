import AppKit
import SwiftUI

/// Puts the welcome window on screen at launch instead of the empty untitled
/// document — or, on current macOS releases, instead of the Open panel that
/// `DocumentGroup` raises by itself.
///
/// Both launch paths are covered because AppKit picks between them:
/// `applicationOpenUntitledFile(_:)` handles the classic untitled-document
/// path, and `applicationDidFinishLaunching(_:)` handles the newer app-centric
/// Open panel, which AppKit raises without ever consulting the delegate.
@MainActor
final class MarkdownEditorAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard WelcomeWindowPreferences.showsAtLaunch, isLaunchingEmpty else {
            return
        }

        dismissLaunchOpenPanels()
        WelcomeWindowController.shared.show()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard WelcomeWindowPreferences.showsAtLaunch else {
            return false
        }

        WelcomeWindowController.shared.show()
        return true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows,
            WelcomeWindowPreferences.showsAtLaunch
        else {
            return true
        }

        WelcomeWindowController.shared.show()
        return false
    }

    /// True when nothing was restored, opened from Finder, or handed over by
    /// another app, so the landing window is the only thing worth showing.
    private var isLaunchingEmpty: Bool {
        guard NSDocumentController.shared.documents.isEmpty else {
            return false
        }
        return !NSApp.windows.contains { window in
            window.isVisible && !(window is NSPanel)
        }
    }

    private func dismissLaunchOpenPanels() {
        for window in NSApp.windows {
            (window as? NSOpenPanel)?.cancel(nil)
        }
    }
}
