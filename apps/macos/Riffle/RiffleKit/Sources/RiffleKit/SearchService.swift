// The client for the search API: POST /search, GET /labels, and GET /health.

import Foundation

public enum SearchRequest: Equatable, Sendable {
    /// Claude reads the text.
    case text(String)
    /// The API uses the filters as they are.
    case filters(SearchFilters)
}

public enum SearchError: Error, Equatable, Sendable {
    /// The API did not accept the token.
    case unauthorized
    /// The API rejected the request, for example an unknown label.
    case badRequest(String)
    /// A 500, another unexpected status, or a response that Riffle cannot read.
    case server
    case timeout
    case network
}

public protocol SearchService: Sendable {
    func search(_ request: SearchRequest) async throws -> SearchResponse
    func labels() async throws -> [LabelInfo]
    /// Starts a cold Lambda. Also checks the URL and the token.
    func health() async throws -> Health
}

public struct HTTPSearchService: SearchService {
    /// Riffle always asks for the maximum, so the order of the results does not change with the limit.
    static let limit = 50
    /// A little more than the 30-second Lambda timeout.
    static let timeout: TimeInterval = 35

    enum Endpoint: Equatable {
        case search(SearchRequest)
        case labels
        case health
    }

    private struct TextBody: Encodable {
        let q: String
        let limit: Int
    }

    private struct FiltersBody: Encodable {
        let filters: SearchFilters
        let limit: Int
    }

    private struct LabelsBody: Decodable {
        let labels: [LabelInfo]
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    let connection: Connection
    let session: URLSession

    public init(connection: Connection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    public func search(_ request: SearchRequest) async throws -> SearchResponse {
        let (data, response) = try await send(.search(request))
        return try Self.decode(SearchResponse.self, from: data, response: response)
    }

    public func labels() async throws -> [LabelInfo] {
        let (data, response) = try await send(.labels)
        return try Self.decode(LabelsBody.self, from: data, response: response).labels
    }

    public func health() async throws -> Health {
        let (data, response) = try await send(.health)
        return try Self.decode(Health.self, from: data, response: response)
    }

    private func send(_ endpoint: Endpoint) async throws -> (Data, URLResponse) {
        let request = try makeRequest(endpoint)
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
    }

    func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        var request: URLRequest
        switch endpoint {
        case .search(let search):
            request = URLRequest(url: connection.url.appending(path: "search"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            switch search {
            case .text(let text):
                request.httpBody = try JSONEncoder().encode(TextBody(q: text, limit: Self.limit))
            case .filters(let filters):
                request.httpBody = try JSONEncoder().encode(FiltersBody(filters: filters, limit: Self.limit))
            }
        case .labels:
            request = URLRequest(url: connection.url.appending(path: "labels"))
        case .health:
            request = URLRequest(url: connection.url.appending(path: "health"))
        }
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Returns the body of a 200 response. Throws a `SearchError` for other statuses.
    static func checkStatus(_ data: Data, _ response: URLResponse) throws -> Data {
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw SearchError.server }
        switch status {
        case 200:
            return data
        case 401:
            throw SearchError.unauthorized
        case 400:
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "The search service rejected the request."
            throw SearchError.badRequest(message)
        default:
            throw SearchError.server
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, response: URLResponse) throws -> T {
        let body = try checkStatus(data, response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            // JavaScript's toISOString() always writes milliseconds.
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
        }
        do {
            return try decoder.decode(type, from: body)
        } catch {
            throw SearchError.server
        }
    }

    /// Maps a URLSession error. A cancelled request becomes `CancellationError`, so callers can ignore it.
    static func transportError(_ error: any Error) -> any Error {
        guard let error = error as? URLError else { return error }
        switch error.code {
        case .cancelled: return CancellationError()
        case .timedOut: return SearchError.timeout
        default: return SearchError.network
        }
    }
}
