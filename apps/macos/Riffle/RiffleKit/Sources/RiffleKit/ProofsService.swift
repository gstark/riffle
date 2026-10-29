// The client for the /proofs routes of the search API, and the PDF upload to S3.
// Errors are `SearchError`s, as in SearchService.swift.

import CryptoKit
import Foundation

public protocol ProofsService: Sendable {
    /// The receipts that need a signed-in proof, grouped by site.
    func pending() async throws -> [PendingSite]
    /// A presigned URL for the PDF of the receipt. `sha256` is the base64 SHA-256 of the PDF.
    func uploadTicket(id: String, sha256: String) async throws -> UploadTicket
    /// PUTs the PDF to the presigned URL.
    func upload(_ pdf: Data, to ticket: UploadTicket, sha256: String) async throws
    /// Sends what Riffle saw on the page. The server keeps the page, or says why not.
    func record(_ result: PageResult) async throws -> ProofFidelity
}

public struct HTTPProofsService: ProofsService {
    enum Endpoint: Equatable {
        case pending
        case upload(id: String, sha256: String)
        case result(PageResult)
    }

    private struct SitesBody: Decodable {
        let sites: [PendingSite]
    }

    private struct UploadBody: Encodable {
        let id: String
        let sha256: String
    }

    let connection: Connection
    let session: URLSession

    public init(connection: Connection, session: URLSession = .shared) {
        self.connection = connection
        self.session = session
    }

    /// The base64 SHA-256 of `data`, as S3 wants it in the x-amz-checksum-sha256 header.
    public static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    public func pending() async throws -> [PendingSite] {
        let (data, response) = try await send(makeRequest(.pending))
        return try HTTPSearchService.decode(SitesBody.self, from: data, response: response).sites
    }

    public func uploadTicket(id: String, sha256: String) async throws -> UploadTicket {
        let (data, response) = try await send(makeRequest(.upload(id: id, sha256: sha256)))
        return try HTTPSearchService.decode(UploadTicket.self, from: data, response: response)
    }

    public func upload(_ pdf: Data, to ticket: UploadTicket, sha256: String) async throws {
        let request = Self.uploadRequest(ticket, sha256: sha256)
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: pdf)
        } catch {
            throw HTTPSearchService.transportError(error)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SearchError.server }
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
        case .upload(let id, let sha256):
            request = URLRequest(url: connection.url.appending(path: "proofs/upload"))
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(UploadBody(id: id, sha256: sha256))
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

    /// S3 checks the checksum against the signed header. The archive bucket needs it for Object Lock.
    static func uploadRequest(_ ticket: UploadTicket, sha256: String) -> URLRequest {
        var request = URLRequest(url: ticket.url)
        request.httpMethod = "PUT"
        request.timeoutInterval = HTTPSearchService.timeout
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "x-amz-checksum-sha256")
        return request
    }
}
