// The Sign-in window: the receipts that need a sign-in, grouped by site, and the Riffle browser where you sign in.
// After you sign in, "Make PDFs" lets the proof runner print the receipts of the site.

import AppKit
import RiffleKit
import SwiftUI
import WebKit

/// The visible browser. It shares the Riffle data store with the hidden browser of the proof runner.
@MainActor @Observable
final class Browser {
    let webView = WKWebView(frame: .zero, configuration: RiffleBrowser.configuration())
    private(set) var address = ""
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.address = self.webView.url?.absoluteString ?? ""
            }
        }
    }

    func open(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}

private struct BrowserView: NSViewRepresentable {
    let browser: Browser

    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// While the window is open, Riffle is a regular app with a Dock icon, so it is in the Command-Tab list.
/// You can go to another app, for example to get a password, and come back. When you close the window, Riffle is
/// a menu bar app again.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: ProofsModel) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Receipts That Need Sign-In"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SignInView(model: model, browser: Browser()))
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.center()
        window.delegate = self
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct SignInView: View {
    let model: ProofsModel
    let browser: Browser
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(model.sites, selection: $selection) { site in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(site.merchant).font(.headline)
                        Spacer()
                        Text("\(site.receipts.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text("\(site.site) · \(model.status(of: site.site).text)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .overlay { loadMessage }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.load == .loading || model.isRunning)
            }
        } detail: {
            if let site = model.sites.first(where: { $0.site == selection }) {
                SiteDetail(model: model, site: site, browser: browser)
            } else {
                ContentUnavailableView(
                    "Select a site",
                    systemImage: "person.badge.key",
                    description: Text("Sign in to the site in the browser. Then make the PDFs of its emails.")
                )
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private var loadMessage: some View {
        switch model.load {
        case .notLoaded, .loading:
            if model.sites.isEmpty { ProgressView() }
        case .failed(let error):
            ContentUnavailableView("Riffle cannot get the receipts", systemImage: "exclamationmark.triangle", description: Text(Self.text(for: error)))
        case .loaded:
            if model.sites.isEmpty { ContentUnavailableView("No receipts need a sign-in", systemImage: "checkmark.circle") }
        }
    }

    private static func text(for error: SearchError) -> String {
        switch error {
        case .unauthorized: "Riffle's token is not accepted. Open Settings to replace it."
        case .network: "Riffle cannot reach the search service. Check your connection."
        case .server, .timeout: "The search service failed. Click Refresh to try again."
        case .badRequest(let message): message
        }
    }
}

private struct SiteDetail: View {
    let model: ProofsModel
    let site: PendingSite
    let browser: Browser

    private var count: Int { site.receipts.count }
    private var isRunningHere: Bool { model.runningSite == site.site }

    var body: some View {
        VStack(spacing: 0) {
            List(site.receipts) { receipt in
                Button { browser.open(receipt.signInUrl) } label: {
                    HStack {
                        Text(receipt.date, format: .dateTime.year().month(.abbreviated).day())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(receipt.subject).lineLimit(1)
                        Spacer()
                        if let amount = receipt.amount { Text(amount).monospacedDigit() }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(height: 170)

            Divider()
            HStack(spacing: 8) {
                Button("Back", systemImage: "chevron.left") { browser.webView.goBack() }
                    .labelStyle(.iconOnly)
                Button("Reload", systemImage: "arrow.clockwise") { browser.webView.reload() }
                    .labelStyle(.iconOnly)
                Text(browser.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            BrowserView(browser: browser)
        }
        .navigationTitle(site.merchant)
        .navigationSubtitle(model.status(of: site.site).text)
        .toolbar {
            ToolbarItem {
                if case .working(let done, let total) = model.status(of: site.site) {
                    ProgressView(value: Double(done), total: Double(total)).frame(width: 160)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if isRunningHere {
                    Button("Stop") { model.cancel() }
                } else {
                    Button("Make PDFs for \(count) \(count == 1 ? "email" : "emails")") {
                        Task {
                            await model.makePDFs(site: site.site)
                            await model.refresh()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                }
            }
        }
        // Open the first receipt, so you can sign in at once.
        .onChange(of: site.site, initial: true) {
            if let first = site.receipts.first { browser.open(first.signInUrl) }
        }
    }
}
