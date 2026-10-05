import AppKit
import SwiftUI

/// Puts the welcome window on screen at launch instead of the empty untitled
/// document — or, on current macOS releases, instead of the Open panel that
/// `DocumentGroup` raises by itself.
///
/// Four launch paths are covered because AppKit and SwiftUI pick between them,
/// and not the same way on every release:
///
/// - From macOS 15 the document scene is told not to open anything at launch
///   (see `MarkdownEditorMain`), so a default launch reaches
///   `applicationDidFinishLaunching(_:)` with nothing on screen, and the
///   welcome window is shown there and then.
/// - `applicationOpenUntitledFile(_:)` handles the classic untitled-document
///   path.
/// - `applicationDidFinishLaunching(_:)` handles the newer app-centric Open
///   panel, which AppKit raises without ever consulting the delegate.
/// - When the previous session's documents are being restored, AppKit does
///   neither, and the restored windows arrive *after* launch finishes. That
///   case waits for restoration so the welcome window is not shown for a
///   moment and then immediately replaced.
@MainActor
final class MarkdownEditorAppDelegate: NSObject, NSApplicationDelegate {
    /// How long to wait for restored documents before giving up and showing the
    /// welcome window. Measured restoration on macOS 26 completes in ~0.33s.
    private static let restorationGracePeriod: TimeInterval = 0.75

    private var restorationTimeout: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TextSizeKeyAlias.install()

        guard WelcomeWindowPreferences.showsAtLaunch,
            !WelcomeWindowController.shared.isVisible
        else {
            return
        }

        // AppKit's word for W-1's plain launch: nothing to restore, nothing
        // opened from Finder, nothing handed over by another app.
        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey]
            as? Bool ?? false
        if isDefaultLaunch {
            closeUntouchedUntitledDocuments()
        }

        guard isLaunchingEmpty else {
            return
        }

        // AppKit only raises the app-centric Open panel when it has nothing to
        // restore, so its presence means the welcome window can be shown right
        // away, as can a default launch. Otherwise documents may still be on
        // their way in. Measured on macOS 27, waiting regardless held the
        // welcome window back for the whole grace period on every launch,
        // because restoration with nothing to restore finishes *before* this
        // method runs and its notification is never seen.
        let hadOpenPanel = dismissLaunchOpenPanels()
        if isDefaultLaunch || hadOpenPanel {
            WelcomeWindowController.shared.show()
        } else {
            waitForWindowRestoration()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard WelcomeWindowPreferences.showsAtLaunch else {
            return false
        }

        cancelRestorationWait()
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
            window.isVisible
                && !(window is NSPanel)
                && !WelcomeWindowController.shared.owns(window)
        }
    }

    /// Closes any untitled document nobody has typed in.
    ///
    /// Only called at a default launch, where such a document can only be one
    /// SwiftUI opened by itself. That is what macOS 27 does when the document
    /// scene is not told otherwise, and with the welcome window beside it the
    /// launch put up two windows where W-1 asks for one. On releases where the
    /// scene is told otherwise there is nothing here to close.
    private func closeUntouchedUntitledDocuments() {
        for document in NSDocumentController.shared.documents
        where document.fileURL == nil && !document.isDocumentEdited {
            document.close()
        }
    }

    /// Cancels any Open panel AppKit put up on our behalf, reporting whether
    /// there was one.
    @discardableResult
    private func dismissLaunchOpenPanels() -> Bool {
        var dismissedAny = false
        for window in NSApp.windows {
            guard let panel = window as? NSOpenPanel else { continue }
            panel.cancel(nil)
            dismissedAny = true
        }
        return dismissedAny
    }

    private func waitForWindowRestoration() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowRestorationDidFinish),
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )

        // The notification is only posted when there is something to restore,
        // so a timeout is what covers every other path into this branch.
        let timeout = DispatchWorkItem { [weak self] in
            self?.presentWelcomeWindowIfLaunchIsEmpty()
        }
        restorationTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.restorationGracePeriod,
            execute: timeout
        )
    }

    @objc
    private func windowRestorationDidFinish(_ notification: Notification) {
        presentWelcomeWindowIfLaunchIsEmpty()
    }

    private func presentWelcomeWindowIfLaunchIsEmpty() {
        cancelRestorationWait()

        guard WelcomeWindowPreferences.showsAtLaunch,
            !WelcomeWindowController.shared.isVisible,
            isLaunchingEmpty
        else {
            return
        }

        dismissLaunchOpenPanels()
        WelcomeWindowController.shared.show()
    }

    private func cancelRestorationWait() {
        restorationTimeout?.cancel()
        restorationTimeout = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didFinishRestoringWindowsNotification,
            object: nil
        )
    }
}
