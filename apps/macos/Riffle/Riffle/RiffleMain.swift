// Entry point. Riffle is an agent app: a menu bar item and a floating panel, with no Dock icon.

import AppKit
import KeyboardShortcuts
import Observation
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
    private var proofs: ProofsModel?
    private var signInWindow: SignInWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()
        let panel = PanelController(model: SearchModel(store: KeychainConnectionStore()))
        let loader = WebPageLoader()
        let proofs = ProofsModel(store: KeychainConnectionStore(), makeRunner: { ProofRunner(service: $0, loader: loader) })
        statusItem = StatusItemController(
            toggle: { panel.toggle() },
            openSettings: { panel.show(settings: true) },
            openProofs: { [weak self] in self?.showSignInWindow() }
        )
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { panel.toggle() }
        self.panel = panel
        self.proofs = proofs
        observeBadge()
        // The timer: make the PDFs of new receipts for the sites that Riffle has a session for.
        Task {
            while !Task.isCancelled {
                await proofs.runInBackground()
                try? await Task.sleep(for: ProofsModel.backgroundInterval)
            }
        }
    }

    private func showSignInWindow() {
        guard let proofs else { return }
        let window = signInWindow ?? SignInWindowController(model: proofs)
        signInWindow = window
        window.show()
    }

    /// Shows the badge while a site needs a sign-in again.
    private func observeBadge() {
        guard let proofs else { return }
        let shown = withObservationTracking {
            proofs.needsAttention
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
        statusItem?.setBadge(shown)
    }
}
