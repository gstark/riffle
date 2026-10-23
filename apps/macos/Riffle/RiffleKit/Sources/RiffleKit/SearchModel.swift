// The state that the Riffle views observe: the search, the filters, the results, and the setup.

import Foundation
import Observation

@MainActor @Observable
public final class SearchModel {
    public enum Phase: Equatable, Sendable {
        /// No search yet. The panel shows the example searches.
        case idle
        /// Claude is reading the text.
        case reading
        /// A search with exact filters is running.
        case filtering
        case done
        case failed(SearchError)
    }

    /// The editor row below the filter sentence.
    public enum Editor: Equatable, Sendable {
        case field(FilterField)
        /// The "+ filter" buttons.
        case add
    }

    public enum LabelsState: Equatable, Sendable {
        case notLoaded, loading, failed
        case loaded([LabelInfo])
    }

    public enum SetupError: Error, Equatable, Sendable {
        case invalidURL, missingToken, unauthorized, unreachable, notSaved

        public var message: String {
            switch self {
            case .invalidURL: "Enter a URL that starts with https://."
            case .missingToken: "Enter the token."
            case .unauthorized: "This token is not accepted."
            case .unreachable: "Riffle cannot reach this URL."
            case .notSaved: "Riffle cannot save the token in the Keychain."
            }
        }
    }

    public static let examples = [
        "receipts from amazon last month",
        "flight confirmations with attachments",
        "newest mail from the bank",
    ]

    /// How long a warm-up keeps the Lambda warm enough to skip the next one.
    static let warmUpInterval: TimeInterval = 10 * 60

    /// The text in the search field.
    public var text = ""
    /// The filters of the last search. Nil before the first search.
    public private(set) var filters: SearchFilters?
    public private(set) var source: QuerySource?
    public private(set) var results: [SearchResult] = []
    public private(set) var phase: Phase = .idle
    public var editor: Editor?
    public private(set) var labels: LabelsState = .notLoaded
    /// The date of the newest message in the index, from the last /health call. Shows how up to date the index is.
    public private(set) var newestMessageAt: Date?
    /// True while the setup screen shows for a saved connection, after Settings….
    public var showingSetup = false

    /// True when a URL and token are saved.
    public var isConnected: Bool { service != nil }
    public var needsSetup: Bool { !isConnected || showingSetup }
    public var savedURL: URL? { store.url }
    public var isSearching: Bool { phase == .reading || phase == .filtering }
    /// True when there is text, filters, or results for the clear button and Esc to remove.
    public var canClear: Bool { !text.isEmpty || phase != .idle || filters != nil }

    private let store: any ConnectionStore
    private let makeService: (Connection) -> any SearchService
    private let now: () -> Date
    private var service: (any SearchService)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: SearchRequest?
    @ObservationIgnored private var lastWarmUp: Date?

    public init(
        store: any ConnectionStore,
        makeService: @escaping (Connection) -> any SearchService = { HTTPSearchService(connection: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.makeService = makeService
        self.now = now
        service = store.load().map(makeService)
    }

    // MARK: Search

    /// Claude reads the text. Empty text clears the search.
    /// After a failed filter search, this repeats that search, as the error message says.
    public func submitText() async {
        guard !trimmedText.isEmpty else { return clear() }
        if case .failed = phase, let lastRequest, case .filters = lastRequest {
            return await run(lastRequest)
        }
        await run(.text(trimmedText))
    }

    /// Cancels the running search and removes the text, the filters, and the results.
    public func clear() {
        task?.cancel()
        task = nil
        lastRequest = nil
        text = ""
        filters = nil
        source = nil
        results = []
        phase = .idle
        editor = nil
    }

    public func runExample(_ example: String) async {
        text = example
        await run(.text(example))
    }

    /// Searches with exact filters. The sentence shows the new filters at once.
    public func setFilters(_ filters: SearchFilters) async {
        self.filters = filters
        await run(.filters(filters))
    }

    public func remove(_ field: FilterField) async {
        guard let filters else { return }
        editor = nil
        await setFilters(filters.removing(field))
    }

    /// Closes the editor, or else clears the search. Returns false when there is nothing to close or clear,
    /// so Esc can close the panel.
    public func escape() -> Bool {
        if editor != nil {
            editor = nil
        } else if canClear {
            clear()
        } else {
            return false
        }
        return true
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancels the running search, then runs `request` and waits for it.
    private func run(_ request: SearchRequest) async {
        guard let service else { return }
        task?.cancel()
        lastRequest = request
        if case .text = request { phase = .reading } else { phase = .filtering }

        let task = Task {
            do {
                let response = try await service.search(request)
                guard !Task.isCancelled else { return }
                filters = response.filters
                source = response.source
                results = response.results
                phase = .done
            } catch is CancellationError {
                // A newer search replaced this one.
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error as? SearchError ?? .server)
            }
        }
        self.task = task
        await task.value
    }

    // MARK: Labels

    /// Loads the labels once per app start. After a failure, the next call tries again.
    public func loadLabels() async {
        guard let service else { return }
        switch labels {
        case .loading, .loaded: return
        case .notLoaded, .failed: break
        }
        labels = .loading
        do {
            let all = try await service.labels()
            labels = .loaded(LabelNames.pickable(all))
        } catch {
            labels = .failed
        }
    }

    // MARK: Warm-up

    /// Calls /health to start a cold Lambda, at most once per `warmUpInterval`. Also gets the newest message date.
    public func warmUp() async {
        guard let service else { return }
        if let lastWarmUp, now().timeIntervalSince(lastWarmUp) < Self.warmUpInterval { return }
        lastWarmUp = now()
        if let health = try? await service.health() { newestMessageAt = health.newestMessageAt }
    }

    // MARK: Setup

    /// Checks the URL and token with /health, then saves them. An empty token keeps the saved token.
    public func testAndSave(url urlText: String, token tokenText: String) async throws(SetupError) {
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme == "https", url.host() != nil else { throw SetupError.invalidURL }
        let trimmedToken = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = trimmedToken.isEmpty ? store.load()?.token : trimmedToken else { throw SetupError.missingToken }

        let connection = Connection(url: url, token: token)
        let service = makeService(connection)
        let health: Health
        do {
            health = try await service.health()
        } catch SearchError.unauthorized {
            throw SetupError.unauthorized
        } catch {
            throw SetupError.unreachable
        }
        do {
            try store.save(connection)
        } catch {
            throw SetupError.notSaved
        }

        self.service = service
        lastWarmUp = now()
        newestMessageAt = health.newestMessageAt
        labels = .notLoaded
        showingSetup = false
    }
}
