// The Sign-in window: the receipts that need a sign-in, grouped by site, and the Riffle browser where you sign in.
// After you sign in, "Make PDFs" lets the proof runner print the receipts of the site.

import AppKit
import RiffleKit
import SwiftUI
import WebKit

/// The visible browser. It shares the Riffle data store with the hidden browser of the proof runner.
@MainActor @Observable
final class Browser {
    let webView = RiffleBrowser.webView()
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
            // The same style as a SwiftUI window. Without .fullSizeContentView, SwiftUI puts the content under the
            // toolbar, and you cannot see or scroll to the top of the receipt list.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.toolbarStyle = .unified
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
        .toolbar {
            if let progress = model.progress {
                ToolbarItem(placement: .status) {
                    RunProgress(progress: progress, site: runningMerchant)
                }
                ToolbarItem(placement: .status) {
                    Button("Stop", systemImage: "stop.fill") { model.cancel() }
                        .help("Stop after this receipt, and empty the queue")
                }
            }
        }
        .task { await model.refresh() }
    }

    private var runningMerchant: String {
        model.sites.first { $0.site == model.runningSite }?.merchant ?? model.runningSite ?? ""
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
    /// The number of finished receipts while a run works. The runner works the receipts in list order.
    private var finished: Int? {
        if case .working(let done, _) = model.status(of: site.site) { done } else { nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(Array(site.receipts.enumerated()), id: \.element.id) { index, receipt in
                    ReceiptRow(receipt: receipt, phase: rowPhase(index)) { browser.open(receipt.signInUrl) }
                }
                .frame(height: 170)
                // Follow the receipt that Riffle prints now.
                .onChange(of: finished) {
                    guard let finished, finished < count else { return }
                    withAnimation { proxy.scrollTo(site.receipts[finished].id, anchor: .center) }
                }
            }

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
            ToolbarItem(placement: .primaryAction) {
                switch model.status(of: site.site) {
                case .working, .queued:
                    EmptyView()
                default:
                    Button("Make \(count) \(count == 1 ? "PDF" : "PDFs")", systemImage: "doc.richtext") {
                        Task { await model.makePDFs(site: site.site) }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.glassProminent)
                    .help(model.isRunning ? "Riffle starts this site after the sites before it" : "")
                }
            }
        }
        // Open the first receipt, so you can sign in at once.
        .onChange(of: site.site, initial: true) {
            if let first = site.receipts.first { browser.open(first.signInUrl) }
        }
    }

    private func rowPhase(_ index: Int) -> ReceiptRow.Phase {
        if model.status(of: site.site) == .queued { return .queued }
        guard let finished else { return .idle }
        return index < finished ? .finished : index == finished ? .printing : .queued
    }
}

private struct ReceiptRow: View {
    /// `idle`: the receipt is not in a run. `queued`: the run prints it later.
    enum Phase { case idle, queued, printing, finished }

    let receipt: PendingReceipt
    let phase: Phase
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                // The receipt that Riffle prints now, or a clock when it is in the queue.
                ZStack {
                    switch phase {
                    case .printing: ProgressView().controlSize(.mini)
                    case .queued: Image(systemName: "clock").font(.caption).foregroundStyle(.secondary).help("In the queue")
                    case .idle, .finished: EmptyView()
                    }
                }
                .frame(width: 14)
                Text(receipt.date, format: .dateTime.year().month(.abbreviated).day())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
                Text(receipt.subject).lineLimit(1)
                Spacer()
                if let amount = receipt.amount { Text(amount).monospacedDigit() }
            }
            .fontWeight(phase == .printing ? .semibold : .regular)
            .opacity(phase == .finished ? 0.4 : 1)
            .animation(.easeOut(duration: 0.3), value: phase)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The progress of all sites of the run, in the window toolbar.
private struct RunProgress: View {
    let progress: ProofsModel.Progress
    /// The merchant that Riffle works on now
    let site: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.circular)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(progress.done) of \(progress.total) PDFs")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
    }

    private var detail: String {
        guard let left = progress.timeLeft() else { return site }
        if left < 60 { return "\(site), less than a minute left" }
        let time = Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return "\(site), about \(time) left"
    }
}
