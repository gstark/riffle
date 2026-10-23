import Foundation
import Testing
@testable import RiffleKit

@Suite struct SearchServiceTests {
    private let service = HTTPSearchService(
        connection: Connection(url: URL(string: "https://search.example.com/")!, token: "secret")
    )

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://search.example.com/search")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    // MARK: Requests

    @Test func textRequest() throws {
        let request = try service.makeRequest(.search(.text("acme insurance")))
        #expect(request.url?.absoluteString == "https://search.example.com/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(request)
        #expect(json["q"] as? String == "acme insurance")
        #expect(json["limit"] as? Int == 50)
        #expect(json["filters"] == nil)
    }

    @Test func filtersRequest() throws {
        let filters = SearchFilters(text: "renewal", from: ["acme"], labels: ["Receipts"], sort: .relevance)
        let json = try body(service.makeRequest(.search(.filters(filters))))
        #expect(json["q"] == nil)
        #expect(json["limit"] as? Int == 50)
        let sent = try #require(json["filters"] as? [String: Any])
        #expect(sent["text"] as? String == "renewal")
        #expect(sent["from"] as? [String] == ["acme"])
        #expect(sent["labels"] as? [String] == ["Receipts"])
        #expect(sent["sort"] as? String == "relevance")
        #expect(sent["after"] is NSNull)
    }

    @Test(arguments: [
        (HTTPSearchService.Endpoint.labels, "https://search.example.com/labels"),
        (HTTPSearchService.Endpoint.health, "https://search.example.com/health"),
    ])
    func getRequests(endpoint: HTTPSearchService.Endpoint, url: String) throws {
        let request = try service.makeRequest(endpoint)
        #expect(request.url?.absoluteString == url)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
    }

    @Test func urlWithoutTrailingSlash() throws {
        let service = HTTPSearchService(connection: Connection(url: URL(string: "https://search.example.com")!, token: "t"))
        #expect(try service.makeRequest(.health).url?.absoluteString == "https://search.example.com/health")
    }

    @Test func bearerTokenAndTimeout() throws {
        let request = try service.makeRequest(.labels)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.timeoutInterval == 35)
    }

    // MARK: Responses

    private let searchJSON = """
    {
      "query": {
        "text": "insurance renewal", "from": ["acme"], "to": [], "after": "2024-01-01", "before": null,
        "labels": [], "includeSpamTrash": false, "hasAttachment": true, "sort": "relevance", "source": "claude"
      },
      "results": [{
        "id": "m1", "threadId": "t1", "date": "2024-01-26T15:04:05.123Z",
        "from": "Acme Insurance <support@insurer.example>", "subject": "Your renewal", "snippet": "Your policy renews",
        "labels": ["INBOX", "Home"], "hasAttachment": true,
        "gmailUrl": "https://mail.google.com/mail/?authuser=me%40example.com#all/t1"
      }],
      "timings": { "parseMs": 900, "embedMs": 80, "searchMs": 40 }
    }
    """

    @Test func decodesSearchResponse() throws {
        let decoded = try HTTPSearchService.decode(SearchResponse.self, from: Data(searchJSON.utf8), response: response(200))
        #expect(decoded.source == .claude)
        #expect(decoded.filters == SearchFilters(
            text: "insurance renewal", from: ["acme"], after: Day(year: 2024, month: 1, day: 1),
            hasAttachment: true, sort: .relevance
        ))
        let result = try #require(decoded.results.first)
        #expect(result.subject == "Your renewal")
        #expect(result.labels == ["INBOX", "Home"])
        #expect(abs(result.date.timeIntervalSince1970 - 1_706_281_445.123) < 0.001)
        #expect(result.gmailUrl.absoluteString == "https://mail.google.com/mail/?authuser=me%40example.com#all/t1")
    }

    @Test(arguments: [QuerySource.claude, .plain, .filters])
    func decodesEachSource(_ source: QuerySource) throws {
        let json = searchJSON.replacingOccurrences(of: "\"source\": \"claude\"", with: "\"source\": \"\(source.rawValue)\"")
        let decoded = try HTTPSearchService.decode(SearchResponse.self, from: Data(json.utf8), response: response(200))
        #expect(decoded.source == source)
    }

    @Test func decodesDateWithoutFraction() throws {
        let json = searchJSON.replacingOccurrences(of: "15:04:05.123Z", with: "15:04:05Z")
        let decoded = try HTTPSearchService.decode(SearchResponse.self, from: Data(json.utf8), response: response(200))
        #expect(decoded.results.first?.date == Date(timeIntervalSince1970: 1_706_281_445))
    }

    @Test func decodesLabels() throws {
        struct Body: Decodable { let labels: [LabelInfo] }
        let json = #"{"labels": [{"name": "INBOX", "type": "system"}, {"name": "Receipts", "type": "user"}]}"#
        let decoded = try HTTPSearchService.decode(Body.self, from: Data(json.utf8), response: response(200))
        #expect(decoded.labels == [LabelInfo(name: "INBOX", type: "system"), LabelInfo(name: "Receipts", type: "user")])
    }

    @Test func decodesHealth() throws {
        let json = #"{"ok": true, "newestMessageAt": "2026-10-23T14:42:00.000Z"}"#
        let decoded = try HTTPSearchService.decode(Health.self, from: Data(json.utf8), response: response(200))
        #expect(decoded.newestMessageAt == Date(timeIntervalSince1970: 1_792_766_520))
    }

    @Test func decodesHealthOfAnEmptyIndex() throws {
        let json = #"{"ok": true, "newestMessageAt": null}"#
        let decoded = try HTTPSearchService.decode(Health.self, from: Data(json.utf8), response: response(200))
        #expect(decoded.newestMessageAt == nil)
    }

    @Test func unauthorized() {
        #expect(throws: SearchError.unauthorized) {
            try HTTPSearchService.decode(SearchResponse.self, from: Data(), response: response(401))
        }
    }

    @Test func badRequestKeepsMessage() {
        let json = #"{"error": "Unknown label: Bills"}"#
        #expect(throws: SearchError.badRequest("Unknown label: Bills")) {
            try HTTPSearchService.decode(SearchResponse.self, from: Data(json.utf8), response: response(400))
        }
    }

    @Test(arguments: [500, 502, 404])
    func serverError(_ status: Int) {
        #expect(throws: SearchError.server) {
            try HTTPSearchService.decode(SearchResponse.self, from: Data(#"{"error": "Internal error"}"#.utf8), response: response(status))
        }
    }

    @Test func unreadableBodyIsServerError() {
        #expect(throws: SearchError.server) {
            try HTTPSearchService.decode(SearchResponse.self, from: Data("{}".utf8), response: response(200))
        }
    }

    // MARK: Transport errors

    @Test func timeout() {
        #expect(HTTPSearchService.transportError(URLError(.timedOut)) as? SearchError == .timeout)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .networkConnectionLost])
    func network(_ code: URLError.Code) {
        #expect(HTTPSearchService.transportError(URLError(code)) as? SearchError == .network)
    }

    @Test func cancelled() {
        #expect(HTTPSearchService.transportError(URLError(.cancelled)) is CancellationError)
    }
}
