import Foundation
@testable import RiffleKit

/// Records the calls in order. `fidelity` is the answer of `record`.
actor FakeProofsService: ProofsService {
    enum Call: Equatable {
        case pending
        case ticket(String)
        case upload(String)
        case record(String)
    }

    var sites: [PendingSite]
    var fidelity: String
    /// The upload of these receipt IDs fails.
    var failingUploads: Set<String>
    var pendingError: SearchError?
    private(set) var calls: [Call] = []
    private(set) var results: [PageResult] = []

    init(sites: [PendingSite] = [], fidelity: String = "merchant_page", failingUploads: Set<String> = [], pendingError: SearchError? = nil) {
        self.sites = sites
        self.fidelity = fidelity
        self.failingUploads = failingUploads
        self.pendingError = pendingError
    }

    func setFidelity(_ fidelity: String) {
        self.fidelity = fidelity
    }

    func pending() async throws -> [PendingSite] {
        calls.append(.pending)
        if let pendingError { throw pendingError }
        return sites
    }

    func uploadTicket(id: String, sha256: String) async throws -> UploadTicket {
        calls.append(.ticket(id))
        return UploadTicket(url: URL(string: "https://s3.example.com/\(id)")!, key: "proofs/\(id).pdf")
    }

    func upload(_ pdf: Data, to ticket: UploadTicket, sha256: String) async throws {
        let id = ticket.url.lastPathComponent
        calls.append(.upload(id))
        if failingUploads.contains(id) { throw SearchError.server }
    }

    func record(_ result: PageResult) async throws -> ProofFidelity {
        calls.append(.record(result.id))
        results.append(result)
        return ProofFidelity(fidelity)
    }
}

/// A browser that gives a page for each URL. Missing URLs fail to load.
@MainActor
final class FakePageLoader: PageLoader {
    var pages: [URL: LoadedPage]
    private(set) var loaded: [URL] = []
    private(set) var printed = 0

    init(pages: [URL: LoadedPage] = [:]) {
        self.pages = pages
    }

    func load(_ url: URL) async throws -> LoadedPage {
        loaded.append(url)
        guard let page = pages[url] else { throw URLError(.timedOut) }
        return page
    }

    func pdf() async throws -> Data {
        printed += 1
        return Data("%PDF-1.4".utf8)
    }
}

extension PendingReceipt {
    static func sample(_ id: String, site: String = "uber.com") -> PendingReceipt {
        PendingReceipt(
            id: id, messageId: String(id.split(separator: ":")[0]), date: Date(timeIntervalSince1970: 1_706_281_445),
            subject: "Receipt \(id)", merchant: "Uber", orderId: nil, total: 2345, currency: "USD",
            url: URL(string: "https://\(site)/receipt/\(id)"), printUrl: URL(string: "https://\(site)/print/\(id)")!
        )
    }
}

extension LoadedPage {
    static func receipt(_ url: URL) -> LoadedPage {
        LoadedPage(finalUrl: url, status: 200, hasPasswordField: false, text: "Total $23.45")
    }

    static let signIn = LoadedPage(
        finalUrl: URL(string: "https://auth.uber.com/login")!, status: 200, hasPasswordField: true, text: "Sign in"
    )
}

/// A page for each receipt.
@MainActor
func receiptPages(_ receipts: [PendingReceipt]) -> [URL: LoadedPage] {
    Dictionary(uniqueKeysWithValues: receipts.map { ($0.printUrl, LoadedPage.receipt($0.printUrl)) })
}
