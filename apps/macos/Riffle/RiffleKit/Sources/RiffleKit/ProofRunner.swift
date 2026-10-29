// Makes the signed-in PDFs of one site: load each page, check for a sign-in page, look for the receipt in the text,
// print a page that shows it, and send the result.

import Foundation

/// What the browser saw after it loaded a page.
public struct LoadedPage: Equatable, Sendable {
    public let finalUrl: URL?
    /// HTTP status of the main page, nil when the browser does not know it
    public let status: Int?
    public let hasPasswordField: Bool
    /// Visible text of the page
    public let text: String

    public init(finalUrl: URL?, status: Int?, hasPasswordField: Bool, text: String) {
        self.finalUrl = finalUrl
        self.status = status
        self.hasPasswordField = hasPasswordField
        self.text = text
    }
}

/// A browser with the Riffle session. The app uses a WKWebView.
@MainActor
public protocol PageLoader: AnyObject {
    /// Loads the page and waits until it is ready. Throws when it fails or times out.
    func load(_ url: URL) async throws -> LoadedPage
    /// Prints the loaded page to a PDF with pages.
    func pdf() async throws -> Data
}

/// How the run of one site ended.
public enum SiteOutcome: Equatable, Sendable {
    /// All receipts were tried. `wrong` pages do not show the charge. `skipped` receipts failed and stay pending.
    case done(made: Int, wrong: Int, skipped: Int)
    /// A page asked for a sign-in, or the server saw a sign-in page or a robot check.
    case needsSignIn
    /// Too many receipts failed in sequence.
    case failed(String)
    /// The API did not accept the token.
    case unauthorized
    case cancelled
}

@MainActor
public final class ProofRunner {
    /// The run stops after this many failures in sequence.
    static let maxFailures = 3
    /// The server reads at most this much text. It needs only the total or the order ID.
    static let maxText = 200_000

    private let service: any ProofsService
    private let loader: any PageLoader
    private let pause: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `pause` is the wait between pages, so the site sees the speed of a person.
    public init(
        service: any ProofsService,
        loader: any PageLoader,
        pause: Duration = .seconds(2),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.loader = loader
        self.pause = pause
        self.sleep = sleep
    }

    /// Makes the PDFs of `receipts`, in order. `progress` gets the number of receipts that are finished.
    public func run(_ receipts: [PendingReceipt], progress: (Int) -> Void = { _ in }) async -> SiteOutcome {
        var made = 0
        var wrong = 0
        var skipped = 0
        var failures = 0
        for (index, receipt) in receipts.enumerated() {
            if index > 0 {
                do { try await sleep(pause) } catch { return .cancelled }
            }
            do {
                let result = try await makeProof(receipt)
                if result.needsSignIn { return .needsSignIn }
                // An error page (link_failed) stays pending, as a failed step does.
                if result.isKept { made += 1 } else if result.isWrongPage { wrong += 1 } else { skipped += 1 }
                failures = 0
            } catch is CancellationError {
                return .cancelled
            } catch SearchError.unauthorized {
                return .unauthorized
            } catch {
                skipped += 1
                failures += 1
                if failures >= Self.maxFailures { return .failed(Self.message(error)) }
            }
            progress(index + 1)
        }
        return .done(made: made, wrong: wrong, skipped: skipped)
    }

    /// The fidelity that the server gave the page. Throws when a step fails.
    private func makeProof(_ receipt: PendingReceipt) async throws -> ProofFidelity {
        let page = try await loader.load(receipt.printUrl)
        if SignInCheck.isSignInPage(url: page.finalUrl, hasPasswordField: page.hasPasswordField) {
            return ProofFidelity("login_required")
        }

        // A page without the total or the order ID is not printed. The server records it as a wrong page.
        let pdf = ReceiptScan.shows(receipt, in: page.text) ? try await loader.pdf() : nil
        return try await service.record(PageResult(
            id: receipt.id,
            finalUrl: (page.finalUrl ?? receipt.printUrl).absoluteString,
            status: page.status,
            hasPasswordField: page.hasPasswordField,
            text: String(page.text.prefix(Self.maxText)),
            pdf: pdf
        ))
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case SearchError.badRequest(let message): message
        case SearchError.network: "Riffle cannot reach the search service."
        case SearchError.timeout: "A request timed out."
        case SearchError.server: "The search service failed."
        case let error as LocalizedError: error.errorDescription ?? "\(error)"
        default: "\(error)"
        }
    }
}
