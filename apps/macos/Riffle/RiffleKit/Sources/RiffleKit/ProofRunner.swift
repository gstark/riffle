// Makes the signed-in PDFs of one site: load each page, check for a sign-in page, look for the receipt in the text,
// print a page that shows it, and send the result.

import Foundation
import os

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
    /// All receipts were tried. `wrong` pages do not show the charge. `skipped` receipts failed or asked for a sign-in,
    /// and stay pending.
    case done(made: Int, wrong: Int, skipped: Int)
    /// Pages in sequence asked for a sign-in or showed a robot check, or no page loaded without one.
    case needsSignIn
    /// Too many receipts failed in sequence.
    case failed(String)
    /// The API did not accept the token.
    case unauthorized
    case cancelled
}

/// What happened to one receipt of a run. Each result without a PDF tells why, with the address of the page.
public enum ReceiptResult: Equatable, Sendable {
    /// The server stored the PDF.
    case stored
    /// The page does not show the total or the order ID. No PDF is kept.
    case wrongPage(String)
    /// The page asked for a sign-in, or the site showed a robot check.
    case needsSignIn(String)
    /// A step failed, or the link gave an error page. The receipt stays pending.
    case failed(String)

    /// Why Riffle has no PDF of the receipt. Nil when the server stored the PDF.
    public var message: String? {
        switch self {
        case .stored: nil
        case .wrongPage(let message), .needsSignIn(let message), .failed(let message): message
        }
    }

    /// The receipt needs no more work.
    public var isFinished: Bool {
        switch self {
        case .stored, .wrongPage: true
        case .needsSignIn, .failed: false
        }
    }
}

@MainActor
public final class ProofRunner {
    /// The run stops after this many failures, or this many sign-in pages, in sequence.
    static let maxFailures = 3
    /// The server reads at most this much text. It needs only the total or the order ID.
    static let maxText = 200_000
    /// Open Console.app and filter on the subsystem to see the result of each receipt.
    private static let log = Logger(subsystem: "com.gstark.riffle", category: "proofs")

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

    /// Makes the PDFs of `receipts`, in order. `report` gets the ID and the result of each receipt when it is finished.
    public func run(_ receipts: [PendingReceipt], report: (String, ReceiptResult) -> Void = { _, _ in }) async -> SiteOutcome {
        var made = 0
        var wrong = 0
        var skipped = 0
        var failures = 0
        var signIns = 0
        var signInsInSequence = 0
        for (index, receipt) in receipts.enumerated() {
            if index > 0 {
                do { try await sleep(pause) } catch { return .cancelled }
            }
            do {
                let (page, fidelity) = try await makeProof(receipt)
                let result = Self.result(fidelity, page: page, receipt: receipt)
                Self.log.notice("\(receipt.id, privacy: .public) \(fidelity.fidelity, privacy: .public): \(result.message ?? "stored", privacy: .public)")
                report(receipt.id, result)
                failures = 0
                // One receipt can need another sign-in, for example an AWS bill in the Amazon site. Sign-in pages
                // in sequence show that the session ended.
                if case .needsSignIn = result {
                    skipped += 1
                    signIns += 1
                    signInsInSequence += 1
                    if signInsInSequence >= Self.maxFailures { return .needsSignIn }
                    continue
                }
                signInsInSequence = 0
                // An error page (link_failed) stays pending, as a failed step does.
                switch result {
                case .stored: made += 1
                case .wrongPage: wrong += 1
                case .needsSignIn, .failed: skipped += 1
                }
            } catch is CancellationError {
                return .cancelled
            } catch SearchError.unauthorized {
                return .unauthorized
            } catch {
                skipped += 1
                failures += 1
                signInsInSequence = 0
                Self.log.error("\(receipt.id, privacy: .public) failed at \(Self.address(receipt.printUrl), privacy: .public): \(String(describing: error), privacy: .public)")
                report(receipt.id, .failed(Self.message(error)))
                if failures >= Self.maxFailures { return .failed(Self.message(error)) }
            }
        }
        // No page loaded with the session, so the site needs a sign-in.
        if signIns > 0, made + wrong == 0 { return .needsSignIn }
        return .done(made: made, wrong: wrong, skipped: skipped)
    }

    /// The loaded page, and the fidelity that the server gave it. Throws when a step fails.
    private func makeProof(_ receipt: PendingReceipt) async throws -> (LoadedPage, ProofFidelity) {
        let page = try await loader.load(receipt.printUrl)
        if SignInCheck.isSignInPage(url: page.finalUrl, hasPasswordField: page.hasPasswordField) {
            return (page, ProofFidelity("login_required"))
        }

        // A page without the total or the order ID is not printed. The server records it as a wrong page.
        let pdf = ReceiptScan.shows(receipt, in: page.text) ? try await loader.pdf() : nil
        let fidelity = try await service.record(PageResult(
            id: receipt.id,
            finalUrl: (page.finalUrl ?? receipt.printUrl).absoluteString,
            status: page.status,
            hasPasswordField: page.hasPasswordField,
            text: String(page.text.prefix(Self.maxText)),
            pdf: pdf
        ))
        return (page, fidelity)
    }

    /// The result of a page, with the reason when Riffle has no PDF.
    static func result(_ fidelity: ProofFidelity, page: LoadedPage, receipt: PendingReceipt) -> ReceiptResult {
        let address = address(page.finalUrl ?? receipt.printUrl)
        if fidelity.isKept { return .stored }
        if fidelity.isWrongPage {
            return .wrongPage("The page at \(address) does not show the total or the order ID. Riffle kept no PDF.")
        }
        if fidelity.fidelity == "blocked" { return .needsSignIn("The site showed a robot check at \(address).") }
        if fidelity.needsSignIn { return .needsSignIn("The page asked for a sign-in at \(address).") }
        let status = page.status.map { $0 >= 400 ? " (HTTP \($0))" : "" } ?? ""
        return .failed("The link gave an error page\(status) at \(address).")
    }

    /// The host and the path of a page. The query can contain a token, so it is not shown.
    static func address(_ url: URL) -> String {
        (url.host() ?? url.absoluteString) + url.path()
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case SearchError.badRequest(let message): message
        case SearchError.network: "Riffle cannot reach the search service."
        case SearchError.timeout: "A request timed out."
        case SearchError.server: "The search service failed."
        case let error as LocalizedError: error.errorDescription ?? error.localizedDescription
        default: error.localizedDescription
        }
    }
}
