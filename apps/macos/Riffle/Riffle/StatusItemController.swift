// The menu bar item. A left click opens or closes the panel. A right click shows the menu.

import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let toggle: () -> Void
    private let openSettings: () -> Void
    private let openProofs: () -> Void

    init(toggle: @escaping () -> Void, openSettings: @escaping () -> Void, openProofs: @escaping () -> Void) {
        self.toggle = toggle
        self.openSettings = openSettings
        self.openProofs = openProofs
        super.init()

        let proofs = NSMenuItem(title: "Receipts That Need Sign-In…", action: #selector(proofsClicked), keyEquivalent: "")
        proofs.target = self
        menu.addItem(proofs)
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Riffle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        guard let button = item.button else { return }
        button.image = MenuBarIcon.image
        button.setAccessibilityLabel("Riffle")
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        guard let button = item.button, let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            toggle()
        }
    }

    /// Shows the badged icon when a site needs a sign-in again.
    func setBadge(_ shown: Bool) {
        item.button?.image = shown ? MenuBarIcon.badged : MenuBarIcon.image
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    @objc private func proofsClicked() {
        openProofs()
    }
}
