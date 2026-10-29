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
        /// The site waits in the queue for the running site.
        case queued
        case working(done: Int, total: Int)
        case done(made: Int, wrong: Int, skipped: Int)
        case failed(String)

        public var text: String {
            switch self {
            case .needsSignIn: "Needs sign-in"
            case .ready: "Ready"
            case .queued: "Waiting"
            case .working(let done, let total): "Working \(done) of \(total)"
            case .done(let made, let wrong, let skipped):
                (["Done: \(made) PDFs"] + (wrong > 0 ? ["\(wrong) not receipts"] : []) + (skipped > 0 ? ["\(skipped) failed"] : []))
                    .joined(separator: ", ")
            case .failed(let message): message
            }
        }
    }

    /// The progress of all sites of a run, together.
    public struct Progress: Equatable, Sendable {
        public let done: Int
        public let total: Int
        public let startedAt: Date

        /// The time to finish the run, from the speed so far. Nil until a few receipts are finished.
        public func timeLeft(now: Date = .now) -> TimeInterval? {
            guard done >= 3 else { return nil }
            return now.timeIntervalSince(startedAt) / Double(done) * Double(total - done)
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
    /// The result of each receipt in the last run of its site, by receipt ID.
    public private(set) var results: [String: ReceiptResult] = [:]
    /// The site that Riffle works on now. Riffle works on one site at a time.
    public private(set) var runningSite: String?
    /// The sites that wait for the running site, in order.
    public private(set) var queue: [PendingSite] = []
    /// The receipts of the run: of the finished sites, the running site, and the queue.
    private var runTotal = 0
    /// The receipts of the finished sites of the run.
    private var runDone = 0
    private var runStartedAt: Date?
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

    /// Nil when no run works.
    public var progress: Progress? {
        guard let runningSite, let runStartedAt else { return nil }
        var done = runDone
        if case .working(let current, _) = statuses[runningSite] { done += current }
        return Progress(done: done, total: runTotal, startedAt: runStartedAt)
    }
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

    /// Makes the PDFs of all pending receipts of `site`, after you signed in. While a run works, the site waits in the
    /// queue, and this returns at once.
    public func makePDFs(site: String) async {
        guard let pending = sites.first(where: { $0.site == site }) else { return }
        await work([pending])
    }

    /// Stops the run after its current page, and empties the queue.
    public func cancel() {
        clearQueue()
        task?.cancel()
    }

    /// The timer: makes the PDFs of new receipts of each site that Riffle has a session for.
    public func runInBackground() async {
        guard !isRunning else { return }
        await refresh()
        guard load == .loaded else { return }
        await work(sites.filter { signedInSites.contains($0.site) && !expiredSites.contains($0.site) })
    }

    /// Adds `sites` to the queue. Then, if no run works, runs the queue until it is empty, and gets the pending
    /// receipts again.
    private func work(_ sites: [PendingSite]) async {
        guard let service = store.load().map(makeService) else { return }
        for site in sites where site.site != runningSite && !queue.contains(where: { $0.site == site.site }) {
            queue.append(site)
            statuses[site.site] = .queued
            runTotal += site.receipts.count
        }
        guard !isRunning, !queue.isEmpty else { return }
        runStartedAt = .now
        while !queue.isEmpty {
            let site = queue.removeFirst()
            switch await run(site, service: service) {
            case .unauthorized, .cancelled: clearQueue()
            case .done, .needsSignIn, .failed: break
            }
            runDone += site.receipts.count
        }
        runTotal = 0
        runDone = 0
        runStartedAt = nil
        await refresh()
    }

    private func clearQueue() {
        for site in queue { statuses[site.site] = nil }
        queue = []
    }

    private func run(_ site: PendingSite, service: any ProofsService) async -> SiteOutcome {
        let total = site.receipts.count
        runningSite = site.site
        statuses[site.site] = .working(done: 0, total: total)
        for receipt in site.receipts { results[receipt.id] = nil }
        let runner = makeRunner(service)
        let task = Task { [weak self] in
            var done = 0
            return await runner.run(site.receipts) { id, result in
                done += 1
                self?.results[id] = result
                self?.statuses[site.site] = .working(done: done, total: total)
            }
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
        case .done(let made, let wrong, let skipped):
            statuses[site] = .done(made: made, wrong: wrong, skipped: skipped)
            // A wrong page also proves the session: the page loaded without a sign-in.
            if made + wrong > 0 {
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
