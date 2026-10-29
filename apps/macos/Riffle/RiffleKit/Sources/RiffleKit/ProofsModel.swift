// The state of the Sign-in window and the menu bar badge: the pending receipts by site, and the runs.

import Foundation
import Observation

@MainActor @Observable
public final class ProofsModel {
    public enum SiteStatus: Equatable, Sendable {
        /// Riffle has no session for the site, or the session ended.
        case needsSignIn
        /// Riffle made PDFs with this site before. The timer runs it.
        case ready
        case working(done: Int, total: Int)
        case done(made: Int, skipped: Int)
        case failed(String)

        public var text: String {
            switch self {
            case .needsSignIn: "Needs sign-in"
            case .ready: "Ready"
            case .working(let done, let total): "Working \(done) of \(total)"
            case .done(let made, 0): "Done: \(made) PDFs"
            case .done(let made, let skipped): "Done: \(made) PDFs, \(skipped) failed"
            case .failed(let message): message
            }
        }
    }

    public enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded
        case failed(SearchError)
    }

    /// The timer runs the sites again after this time.
    public static let backgroundInterval: Duration = .seconds(6 * 60 * 60)
    private static let signedInSitesKey = "signedInSites"
    private static let expiredSitesKey = "expiredSites"

    public private(set) var sites: [PendingSite] = []
    public private(set) var load: LoadState = .notLoaded
    private var statuses: [String: SiteStatus] = [:]
    /// The site of the running run. Only one run works at a time.
    public private(set) var runningSite: String?
    /// Sites where a run made PDFs. The timer runs these sites.
    private var signedInSites: Set<String> {
        didSet { defaults.set(signedInSites.sorted(), forKey: Self.signedInSitesKey) }
    }
    /// Signed-in sites whose session ended. The timer skips them until a run with a new sign-in works.
    private var expiredSites: Set<String> {
        didSet { defaults.set(expiredSites.sorted(), forKey: Self.expiredSitesKey) }
    }

    /// True when the session of a signed-in site ended. The menu bar icon shows a badge.
    public var needsAttention: Bool { !expiredSites.isEmpty }

    public var isRunning: Bool { runningSite != nil }
    public var pendingCount: Int { sites.reduce(0) { $0 + $1.receipts.count } }

    private let store: any ConnectionStore
    private let makeService: (Connection) -> any ProofsService
    private let makeRunner: (any ProofsService) -> ProofRunner
    private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<SiteOutcome, Never>?

    public init(
        store: any ConnectionStore,
        makeService: @escaping (Connection) -> any ProofsService = { HTTPProofsService(connection: $0) },
        makeRunner: @escaping (any ProofsService) -> ProofRunner,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.makeService = makeService
        self.makeRunner = makeRunner
        self.defaults = defaults
        signedInSites = Set(defaults.stringArray(forKey: Self.signedInSitesKey) ?? [])
        expiredSites = Set(defaults.stringArray(forKey: Self.expiredSitesKey) ?? [])
    }

    public func status(of site: String) -> SiteStatus {
        statuses[site] ?? (signedInSites.contains(site) && !expiredSites.contains(site) ? .ready : .needsSignIn)
    }

    /// Gets the pending receipts again. Keeps the sites that a run removed until the next refresh.
    public func refresh() async {
        guard let service = store.load().map(makeService) else { return }
        load = .loading
        do {
            sites = try await service.pending()
            load = .loaded
        } catch {
            load = .failed(error as? SearchError ?? .server)
        }
    }

    /// Makes the PDFs of all pending receipts of `site`, after you signed in. Does nothing while a run works.
    public func makePDFs(site: String) async {
        guard let pending = sites.first(where: { $0.site == site }) else { return }
        _ = await run(pending)
    }

    /// Stops the running run after its current page.
    public func cancel() {
        task?.cancel()
    }

    /// The timer: makes the PDFs of new receipts of each site that Riffle has a session for.
    public func runInBackground() async {
        guard !isRunning else { return }
        await refresh()
        guard load == .loaded else { return }
        for site in sites where signedInSites.contains(site.site) && !expiredSites.contains(site.site) {
            switch await run(site) {
            case .unauthorized, .cancelled: return
            case .done, .needsSignIn, .failed: break
            }
        }
    }

    private func run(_ site: PendingSite) async -> SiteOutcome {
        guard !isRunning, let service = store.load().map(makeService) else { return .cancelled }
        let total = site.receipts.count
        runningSite = site.site
        statuses[site.site] = .working(done: 0, total: total)
        let runner = makeRunner(service)
        let task = Task { [weak self] in
            await runner.run(site.receipts) { done in self?.statuses[site.site] = .working(done: done, total: total) }
        }
        self.task = task
        let outcome = await task.value
        self.task = nil
        runningSite = nil
        record(outcome, for: site.site)
        return outcome
    }

    private func record(_ outcome: SiteOutcome, for site: String) {
        switch outcome {
        case .done(let made, let skipped):
            statuses[site] = .done(made: made, skipped: skipped)
            if made > 0 {
                signedInSites.insert(site)
                expiredSites.remove(site)
            }
        case .needsSignIn:
            statuses[site] = .needsSignIn
            if signedInSites.contains(site) { expiredSites.insert(site) }
        case .failed(let message):
            statuses[site] = .failed(message)
        case .unauthorized:
            statuses[site] = .failed("Riffle's token is not accepted. Open Settings to replace it.")
        case .cancelled:
            statuses[site] = nil
        }
    }
}
