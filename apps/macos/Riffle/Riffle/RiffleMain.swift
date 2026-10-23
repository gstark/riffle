// Entry point. Riffle is an agent app: a menu bar item and a floating panel, with no Dock icon.

import AppKit
import KeyboardShortcuts
import RiffleKit

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.e, modifiers: [.option, .command]))
}

@main
@MainActor
enum RiffleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        // NSApplication keeps only a weak reference to its delegate.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()
        let panel = PanelController(model: SearchModel(store: KeychainConnectionStore()))
        statusItem = StatusItemController(
            toggle: { panel.toggle() },
            openSettings: { panel.show(settings: true) }
        )
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { panel.toggle() }
        self.panel = panel
    }
}
