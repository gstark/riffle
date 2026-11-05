// Riffle is a menu bar app. While a regular window is open (Receipts, or the Sign-in window), Riffle is a regular app
// with a Dock icon, so it is in the Command-Tab list. You can go to another app and come back. When the last regular
// window closes, Riffle is a menu bar app again.

import AppKit

@MainActor
enum RegularWindows {
    static func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Call this from `windowWillClose`. The window still counts as visible then, so the check leaves it out.
    /// The search panel is an NSPanel, and the hidden print window is never on the screen.
    static func willClose(_ window: NSWindow) {
        let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && !($0 is NSPanel) }
        if !othersOpen { NSApp.setActivationPolicy(.accessory) }
    }
}
