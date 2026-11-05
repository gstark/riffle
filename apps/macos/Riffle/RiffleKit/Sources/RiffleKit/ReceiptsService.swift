// The client for the /receipts routes of the search API.
// Errors are `SearchError`s, as in SearchService.swift.

import Foundation

/// Which PDF of a receipt.
public enum PdfChoice: String, Sendable, Encodable {
    /// The best proof: a signed-in PDF, a merchant PDF, or else the PDF of the email.
    case best
    /// The PDF of the email.
    case email
}

public protocol ReceiptsService: Sendable {
    /// All receipts, newest first.
    func receipts() async throws -> [Receipt]
    /// A link to a PDF of the receipt. The link works for a few minutes.
    func pdfURL(id: String, which: PdfChoice) async throws -> URL
}

public struct HTTPReceiptsService: ReceiptsService {
    enum Endpoint: Equatable {
        case list
        case pdf(String, PdfChoice)
    }

    private struct ListBody: Decodable {
        let receipts: [Receipt]
    }

    private struct PdfRequest: Encodable {
        let id: String
        let which: PdfChoice
    }

    private struct PdfBody: Decodable {
        let url: URL
    }

    let connection: Connection
    let session: URLSession

    public init(connection: Connection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    public func receipts() async throws -> [Receipt] {
        let (data, response) = try await send(makeRequest(.list))
        return try HTTPSearchService.decode(ListBody.self, from: data, response: response).receipts
    }

    public func pdfURL(id: String, which: PdfChoice) async throws -> URL {
        let (data, response) = try await send(makeRequest(.pdf(id, which)))
        return try HTTPSearchService.decode(PdfBody.self, from: data, response: response).url
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
        case .list:
            request = URLRequest(url: connection.url.appending(path: "receipts"))
        case .pdf(let id, let which):
            request = URLRequest(url: connection.url.appending(path: "receipts/pdf"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(PdfRequest(id: id, which: which))
        }
        request.timeoutInterval = HTTPSearchService.timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        return request
    }
}
