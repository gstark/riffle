import Foundation
import Testing
@testable import RiffleKit

@Suite struct ReceiptsServiceTests {
    private let service = HTTPReceiptsService(
        connection: Connection(url: URL(string: "https://search.example.com/")!, token: "secret")
    )

    @Test func listRequest() throws {
        let request = try service.makeRequest(.list)
        #expect(request.url?.absoluteString == "https://search.example.com/receipts")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func pdfRequest() throws {
        let request = try service.makeRequest(.pdf("m1:0", .email))
        #expect(request.url?.absoluteString == "https://search.example.com/receipts/pdf")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["id": "m1:0", "which": "email"])
    }
}
