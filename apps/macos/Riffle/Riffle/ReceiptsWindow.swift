// The Receipts window: a ledger of the receipts that Riffle found in your mail. The sidebar groups them by merchant
// or by month, the search field filters them, and the detail shows the receipt and its email.

import AppKit
import RiffleKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ReceiptsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: ReceiptsModel

    init(model: ReceiptsModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.receiptsWindowSize),
            // The same style as a SwiftUI window. See SignInWindowController.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.toolbarStyle = .unified
        window.title = "Receipts"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ReceiptsView(model: model, pdfs: PDFCache()))
        window.setContentSize(Theme.receiptsWindowSize)
        window.center()
        window.setFrameAutosaveName("Receipts")
        window.delegate = self
    }

    /// Opens the window and gets the receipts again, so new receipts show. The filters stay.
    func show() {
        RegularWindows.show(window)
        if model.load != .loading { Task { await model.refresh() } }
    }

    func windowWillClose(_ notification: Notification) {
        RegularWindows.willClose(window)
    }
}

struct ReceiptsView: View {
    let model: ReceiptsModel
    let pdfs: PDFCache
    @State private var sidebar: ReceiptsSidebar.Mode = .merchants

    var body: some View {
        NavigationSplitView {
            ReceiptsSidebar(model: model, mode: $sidebar)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } content: {
            ReceiptLedger(model: model)
                .navigationSplitViewColumnWidth(min: 500, ideal: 600)
        } detail: {
            if let receipt = model.selected {
                ReceiptDetail(model: model, receipt: receipt, pdfs: pdfs)
            } else {
                ContentUnavailableView(
                    "Select a receipt",
                    systemImage: "receipt",
                    description: Text("The receipt shows here, with its PDF and its email.")
                )
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.load == .loading)
                    .help("Get the receipts again")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Export CSV", systemImage: "square.and.arrow.up", action: exportCSV)
                    .disabled(model.results.isEmpty)
                    .help("Save the receipts in the list as a CSV file")
            }
        }
        .font(Theme.receiptBodyFont)
        .controlSize(.large)
        .tint(Theme.ink)
    }

    /// Saves the receipts of the list, one row each, for a spreadsheet.
    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Receipts.csv"
        panel.message = "The CSV file has the \(model.results.count) receipts in the list."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.csv().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
