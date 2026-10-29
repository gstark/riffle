// The client for the /proofs routes of the search API.
// Errors are `SearchError`s, as in SearchService.swift.

import Foundation

public protocol ProofsService: Sendable {
    /// The receipts that need a signed-in proof, grouped by site.
    func pending() async throws -> [PendingSite]
    /// Sends what Riffle saw on the page, and its PDF. The server keeps the PDF, or says why not.
    func record(_ result: PageResult) async throws -> ProofFidelity
}

public struct HTTPProofsService: ProofsService {
    enum Endpoint: Equatable {
        case pending
        case result(PageResult)
    }

    private struct SitesBody: Decodable {
        let sites: [PendingSite]
    }

    let connection: Connection
    let session: URLSession

    public init(connection: Connection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    public func pending() async throws -> [PendingSite] {
        let (data, response) = try await send(makeRequest(.pending))
        return try HTTPSearchService.decode(SitesBody.self, from: data, response: response).sites
    }

    public func record(_ result: PageResult) async throws -> ProofFidelity {
        let (data, response) = try await send(makeRequest(.result(result)))
        return try HTTPSearchService.decode(ProofFidelity.self, from: data, response: response)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw HTTPSearchService.transportError(error)
        }
    }

    func makeRequest(_ endpoint: Endpoint) throws -> URLRequest {
        var request: URLRequest
        switch endpoint {
        case .pending:
            request = URLRequest(url: connection.url.appending(path: "proofs/pending"))
        case .result(let result):
            request = URLRequest(url: connection.url.appending(path: "proofs/result"))
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(result)
        }
        if request.httpMethod == "POST" { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.timeoutInterval = HTTPSearchService.timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
