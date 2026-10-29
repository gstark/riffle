// The Riffle browser: a WebKit data store that only Riffle uses, the visible browser of the Sign-in window, and the
// hidden browser that loads and prints the receipt pages. Both browsers use the same data store, so they share
// your sign-ins. The sessions stay on this Mac.

import AppKit
import RiffleKit
import WebKit

@MainActor
enum RiffleBrowser {
    /// Fixed, so the sessions stay after Riffle quits.
    private static let storeID = UUID(uuidString: "6F1B2C55-0B5E-4C1D-9E7A-2D3C4B5A6F70")!
    static let dataStore = WKWebsiteDataStore(forIdentifier: storeID)

    /// A browser with the Riffle data store. You can inspect it with the Develop menu of Safari.
    static func webView(frame: NSRect = .zero) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Look like Safari. Some sites do not trust a browser without "Safari" in the user agent.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.isInspectable = true
        return webView
    }
}

struct PrintFailed: LocalizedError {
    var errorDescription: String? { "Riffle could not print the page." }
}

/// Loads a page in a hidden WKWebView and prints it to a PDF with pages.
@MainActor
final class WebPageLoader: NSObject, PageLoader, WKNavigationDelegate {
    private static let timeout: Duration = .seconds(30)
    /// Receipt pages often fill in their content with scripts after the load event.
    private static let settle: Duration = .seconds(2)
    /// A page with less visible text is probably not ready. Riffle waits for more text, up to `maxSettle` in total.
    private static let thinText = 200
    private static let maxSettle: Duration = .seconds(10)
    private static let poll: Duration = .seconds(1)
    private static let pageScript = """
        return {
          hasPasswordField: document.querySelector('input[type="password"]') !== null,
          text: document.body ? document.body.innerText : ""
        };
        """

    private let webView = RiffleBrowser.webView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1400))
    /// WebKit prints only a view in a window. The window stays off the screen.
    private let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1024, height: 1400), styleMask: [.borderless], backing: .buffered, defer: false)
    private var navigation: CheckedContinuation<Void, any Error>?
    private var printed: CheckedContinuation<Bool, Never>?
    private var status: Int?

    override init() {
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws -> LoadedPage {
        status = nil
        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.timeout)
            self?.webView.stopLoading()
            self?.finish(.failure(URLError(.timedOut)))
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            finish(.failure(CancellationError()))
            navigation = continuation
            webView.load(URLRequest(url: url))
        }
        try await Task.sleep(for: Self.settle)

        var waited = Self.settle
        var page = try await readPage()
        while !page.hasPasswordField, page.text.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.thinText,
              waited < Self.maxSettle {
            try await Task.sleep(for: Self.poll)
            waited += Self.poll
            page = try await readPage()
        }
        return page
    }

    private func readPage() async throws -> LoadedPage {
        let info = try await webView.callAsyncJavaScript(Self.pageScript, contentWorld: .defaultClient) as? [String: Any]
        return LoadedPage(
            finalUrl: webView.url,
            status: status,
            hasPasswordField: info?["hasPasswordField"] as? Bool ?? false,
            text: info?["text"] as? String ?? ""
        )
    }

    func pdf() async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appending(path: "riffle-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: file) }

        let info = NSPrintInfo(dictionary: [.jobDisposition: NSPrintInfo.JobDisposition.save, .jobSavingURL: file])
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // Without a frame, WebKit prints empty pages.
        operation.view?.frame = webView.bounds

        let success = await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard success, let data = try? Data(contentsOf: file), !data.isEmpty else { throw PrintFailed() }
        return data
    }

    /// AppKit calls this on the thread of the print operation, not on the main thread.
    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.printFinished(success) }
    }

    private func printFinished(_ success: Bool) {
        printed?.resume(returning: success)
        printed = nil
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let navigation else { return }
        self.navigation = nil
        navigation.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame {
            status = (navigationResponse.response as? HTTPURLResponse)?.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    /// A redirect by a script cancels the first navigation. Then wait for the next one, or for the timeout.
    private func failed(_ error: any Error) {
        if (error as? URLError)?.code == .cancelled { return }
        finish(.failure(error))
    }
}
