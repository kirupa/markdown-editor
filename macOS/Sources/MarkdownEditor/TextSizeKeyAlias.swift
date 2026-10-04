import AppKit

/// Lets `⌘=` reach View ▸ Make Text Bigger, as well as the `⌘+` it shows.
///
/// On most layouts "+" is the shifted "=", so the menu's `⌘+` is really
/// `⇧⌘=`, and AppKit matches a key equivalent against the character the keys
/// make: `⌘=` on its own matched nothing. Measured by handing both events to a
/// menu holding a `⌘+` item — `⇧⌘=` fired it, `⌘=` did not. Every Mac app that
/// zooms answers the unshifted key too, because that is what fingers press;
/// AppKit apps do it with a hidden alternate item, which SwiftUI's commands
/// cannot declare, so the key is redirected here instead.
@MainActor
enum TextSizeKeyAlias {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function])
            guard modifiers == .command,
                event.charactersIgnoringModifiers == "=",
                let item = NSApp.mainMenu.flatMap(makeTextBiggerItem(in:)),
                let menu = item.menu
            else {
                return event
            }
            menu.update()
            guard item.isEnabled else { return event }
            menu.performActionForItem(at: menu.index(of: item))
            return nil
        }
    }

    private static func makeTextBiggerItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == "+",
                item.keyEquivalentModifierMask == .command {
                return item
            }
            if let submenu = item.submenu,
                let found = makeTextBiggerItem(in: submenu) {
                return found
            }
        }
        return nil
    }
}
