// A PDF of a receipt: the best proof, or the PDF of the email. Riffle asks the search service for a short-lived link,
// downloads the file, and shows it with PDFKit. The window keeps the last files, so a receipt shows at once when you
// come back to it.

import PDFKit
import RiffleKit
import SwiftUI

/// The PDF files that the window downloaded, newest last.
@MainActor
final class PDFCache {
    private static let limit = 40
    private var files: [String: Data] = [:]
    private var order: [String] = []

    subscript(key: String) -> Data? {
        get { files[key] }
        set {
            files[key] = newValue
            order.removeAll { $0 == key }
            guard newValue != nil else { return }
            order.append(key)
            if order.count > Self.limit { files[order.removeFirst()] = nil }
        }
    }
}

struct ProofPDFView: View {
    private enum Phase {
        case loading
        case loaded(PDFDocument)
        case failed(String)
    }

    let model: ReceiptsModel
    let receipt: Receipt
    let which: PdfChoice
    let cache: PDFCache

    @State private var phase: Phase = .loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .controlSize(.large)
            case .loaded(let document):
                PDFKitView(document: document)
            case .failed(let message):
                ContentUnavailableView("Riffle cannot show the PDF", systemImage: "doc.badge.ellipsis", description: Text(message))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: key) { await load() }
    }

    private var key: String { "\(receipt.id) \(which.rawValue)" }

    private func load() async {
        if let data = cache[key], let document = PDFDocument(data: data) {
            phase = .loaded(document)
            return
        }
        phase = .loading
        do {
            let url = try await model.pdfURL(for: receipt, which: which)
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let document = PDFDocument(data: data) else {
                phase = .failed("The archive did not give a PDF file.")
                return
            }
            cache[key] = data
            phase = .loaded(document)
        } catch {
            // Another receipt was selected while this one loaded.
            guard !Task.isCancelled else { return }
            phase = .failed(Self.text(for: error))
        }
    }

    private static func text(for error: any Error) -> String {
        switch error as? SearchError {
        case .unauthorized: "Riffle's token is not accepted. Open Settings to replace it."
        case .badRequest(let message): message
        case .network: "Riffle cannot reach the search service. Check your connection."
        case .server, .timeout, nil: "The PDF did not load. Select the receipt again to try again."
        }
    }
}

private struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}
