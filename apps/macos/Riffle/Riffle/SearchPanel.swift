// The floating panel and its controller: position, height, fade-in, and the cases that close it.

import AppKit
import RiffleKit
import SwiftUI

/// A borderless panel that takes key focus without activating Riffle, so the previous app stays in front.
final class SearchPanel: NSPanel {
    var onEscape: () -> Void = {}

    // A borderless window cannot become key by default.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The panel does not make Riffle the active app, so AppKit can skip the main menu for key equivalents.
    /// Check the Edit menu here, so ⌘A, ⌘C, ⌘V, ⌘X, and ⌘Z always reach the text fields.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true
    }

    /// Esc, when no view in the panel handles it.
    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

/// Lets the views know that the panel opened again, so the search field can take the cursor.
@MainActor @Observable
final class PanelState {
    var openCount = 0
}

@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private static let startHeight: CGFloat = 120
    private let model: SearchModel
    private let panel = SearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: PanelController.startHeight),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: true
    )
    private let state = PanelState()
    /// When a click outside closed the panel. A click on the menu bar icon comes right after, and must not open it again.
    private var closedByClickAt: Date?
    /// The height that the panel has, or goes to while it animates.
    private var targetHeight = PanelController.startHeight

    init(model: SearchModel) {
        self.model = model
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Theme.panelRadius)

        let hosting = NSHostingView(rootView: RootView(
            model: model,
            state: state,
            close: { [weak self] in self?.hide() },
            open: { [weak self] url in self?.open(url) },
            setHeight: { [weak self] height in self?.setHeight(height) }
        ))
        // The controller sets the window size. The views only report their height.
        hosting.sizingOptions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)

        panel.contentView = background
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.escape() }
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else if let closedByClickAt, Date.now.timeIntervalSince(closedByClickAt) < 0.3 {
            // The click on the icon closed the panel already.
        } else {
            show()
        }
    }

    func show(settings: Bool = false) {
        if settings { model.showingSetup = true }
        position()
        state.openCount += 1

        let fade = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = fade ? 0 : 1
        panel.makeKeyAndOrderFront(nil)
        if fade {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = Theme.fadeIn
            panel.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        Task { await model.warmUp() }
    }

    func hide() {
        model.editor = nil
        panel.orderOut(nil)
    }

    private func escape() {
        if !model.escape() { hide() }
    }

    private func open(_ url: URL) {
        hide()
        NSWorkspace.shared.open(url)
    }

    /// Centered, in the upper third of the screen that has the mouse pointer.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let top = visible.maxY - visible.height * 0.18
        let height = panel.frame.height
        panel.setFrame(
            NSRect(x: visible.midX - Theme.panelWidth / 2, y: top - height, width: Theme.panelWidth, height: height),
            display: false
        )
    }

    /// Changes the height and keeps the top edge in place. While the panel shows, the change animates.
    private func setHeight(_ height: CGFloat) {
        let newHeight = ceil(height)
        // During an animation, the frame has an in-between height. Compare with the height that the panel goes to.
        guard newHeight != targetHeight else { return }
        targetHeight = newHeight
        var frame = panel.frame
        frame.origin.y = frame.maxY - newHeight
        frame.size.height = newHeight

        guard panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.resizeDuration
            context.timingFunction = Theme.resizeTiming
            self.panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.invalidateShadow() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        closedByClickAt = .now
        hide()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
