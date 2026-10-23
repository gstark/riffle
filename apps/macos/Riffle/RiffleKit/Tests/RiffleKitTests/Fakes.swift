import Foundation
@testable import RiffleKit

actor FakeSearchService: SearchService {
    typealias Handler = @Sendable (SearchRequest) async throws -> SearchResponse

    private let handler: Handler
    private let healthError: SearchError?
    private let newestMessageAt: Date?
    private(set) var requests: [SearchRequest] = []
    private(set) var healthCalls = 0
    private(set) var labelCalls = 0

    init(healthError: SearchError? = nil, newestMessageAt: Date? = nil, handler: @escaping Handler = { _ in .sample() }) {
        self.healthError = healthError
        self.newestMessageAt = newestMessageAt
        self.handler = handler
    }

    func search(_ request: SearchRequest) async throws -> SearchResponse {
        requests.append(request)
        return try await handler(request)
    }

    func labels() async throws -> [LabelInfo] {
        labelCalls += 1
        return [LabelInfo(name: "SPAM", type: "system"), LabelInfo(name: "Receipts", type: "user")]
    }

    func health() async throws -> Health {
        healthCalls += 1
        if let healthError { throw healthError }
        return Health(newestMessageAt: newestMessageAt)
    }

    /// Waits until the service has received `count` searches.
    func waitForRequests(_ count: Int) async {
        while requests.count < count { await Task.yield() }
    }
}

@MainActor
final class MemoryConnectionStore: ConnectionStore {
    var saved: Connection?

    init(_ saved: Connection? = nil) {
        self.saved = saved
    }

    var url: URL? { saved?.url }

    func load() -> Connection? { saved }

    func save(_ connection: Connection) throws {
        saved = connection
    }
}

/// A controllable clock.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}

extension Connection {
    static let sample = Connection(url: URL(string: "https://search.example.com/")!, token: "saved-token")
}

extension SearchResult {
    static func sample(_ id: String) -> SearchResult {
        SearchResult(
            id: id, threadId: "t-\(id)", date: Date(timeIntervalSince1970: 1_706_281_445), from: "Acme <support@insurer.example>",
            subject: "Subject \(id)", snippet: "Snippet \(id)", labels: [], hasAttachment: false,
            gmailUrl: URL(string: "https://mail.google.com/mail/#all/t-\(id)")!
        )
    }
}

extension SearchResponse {
    static func sample(
        _ ids: [String] = ["a"], filters: SearchFilters = SearchFilters(text: "renewal", sort: .relevance), source: QuerySource = .claude
    ) -> SearchResponse {
        SearchResponse(filters: filters, source: source, results: ids.map(SearchResult.sample))
    }
}
