import AppKit

/// Opens the app's settings window.
///
/// There is no single API for this that works across the versions of macOS
/// this app runs on. `SettingsLink` needs macOS 14 and is a view rather than an
/// action, so it cannot be called from a button that already exists; and the
/// selector AppKit answers has been renamed twice — `showPreferencesWindow:`
/// became `showSettingsWindow:` in Ventura, and on macOS 27 neither is
/// answered. Measured: sending `showSettingsWindow:` returns false and nothing
/// opens, which is exactly what the gear in the critique rail did.
///
/// So this tries the selectors, and then does what the keyboard shortcut does —
/// performs the app menu's own Settings item. That item is put there by
/// SwiftUI's `Settings` scene, so if it is missing there is no settings window
/// to open at all, and no version of macOS can rename it out from under this.
@MainActor
enum CritiqueSettingsWindow {
    @discardableResult
    static func open() -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        // The menu item first, because it is the one route measured to work.
        //
        // `sendAction` is tried only after it, and its result is not trusted:
        // measured on macOS 27 it returns *true* for `showSettingsWindow:` —
        // something in the responder chain claims the selector — while no
        // window appears. Believing that return value is what made the gear do
        // nothing at all: it reported success and stopped.
        if let item = settingsMenuItem(), let menu = item.menu {
            menu.performActionForItem(at: menu.index(of: item))
            return true
        }
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) {
                return true
            }
        }
        return false
    }

    /// The Settings item in the application menu.
    ///
    /// Found by title rather than by selector, for the same reason the
    /// selectors are not trusted above. Both spellings, because the menu is
    /// named by the system and follows the same rename.
    static func settingsMenuItem() -> NSMenuItem? {
        // The application menu is the first one, whatever the app is called.
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else {
            return nil
        }
        return appMenu.items.first { item in
            let title = item.title
            return title.hasPrefix("Settings") || title.hasPrefix("Preferences")
        }
    }
}
