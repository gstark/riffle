import Foundation
import Testing
@testable import RiffleKit

@Suite struct ProofsServiceTests {
    private let service = HTTPProofsService(
        connection: Connection(url: URL(string: "https://search.example.com/")!, token: "secret")
    )

    private func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://search.example.com/proofs")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @Test func pendingRequest() throws {
        let request = try service.makeRequest(.pending)
        #expect(request.url?.absoluteString == "https://search.example.com/proofs/pending")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test func uploadTicketRequest() throws {
        let request = try service.makeRequest(.upload(id: "m1:0", sha256: "abc="))
        #expect(request.url?.absoluteString == "https://search.example.com/proofs/upload")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try body(request)
        #expect(json["id"] as? String == "m1:0")
        #expect(json["sha256"] as? String == "abc=")
    }

    @Test func resultRequestSendsANullStatus() throws {
        let result = PageResult(id: "m1:0", finalUrl: "https://example.com/", status: nil, hasPasswordField: false, text: "Total")
        let json = try body(service.makeRequest(.result(result)))
        #expect(json["id"] as? String == "m1:0")
        #expect(json["finalUrl"] as? String == "https://example.com/")
        #expect(json["status"] is NSNull)
        #expect(json["hasPasswordField"] as? Bool == false)
        #expect(json["text"] as? String == "Total")
    }

    @Test func uploadRequestSendsTheChecksum() {
        let ticket = UploadTicket(url: URL(string: "https://s3.example.com/proofs/m1/signed-in-0.pdf?X-Amz-Signature=x")!, key: "k")
        let request = HTTPProofsService.uploadRequest(ticket, sha256: "abc=")
        #expect(request.url == ticket.url)
        #expect(request.httpMethod == "PUT")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
        #expect(request.value(forHTTPHeaderField: "x-amz-checksum-sha256") == "abc=")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func sha256IsBase64() {
        #expect(HTTPProofsService.sha256(Data()) == "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=")
    }

    @Test func decodesPendingSites() throws {
        let json = """
        {"sites": [{"site": "amazon.com", "merchant": "Amazon", "receipts": [{
          "id": "m1:0", "messageId": "m1", "date": "2026-03-09T12:00:00.000Z", "subject": "Your order",
          "merchant": "Amazon", "orderId": "112-1234567-1234567", "total": 2345, "currency": "USD", "url": null,
          "printUrl": "https://www.amazon.com/gp/css/summary/print.html?orderID=112-1234567-1234567"
        }]}]}
        """
        struct Body: Decodable { let sites: [PendingSite] }
        let sites = try HTTPSearchService.decode(Body.self, from: Data(json.utf8), response: response(200)).sites
        let receipt = try #require(sites.first?.receipts.first)
        #expect(sites.first?.site == "amazon.com")
        #expect(receipt.url == nil)
        #expect(receipt.signInUrl == receipt.printUrl)
        #expect(receipt.date == Date(timeIntervalSince1970: 1_773_057_600))
    }

    @Test func amountUsesTheMinorUnitsOfTheCurrency() {
        let receipt = PendingReceipt.sample("a:0")
        #expect(receipt.amount?.contains("23.45") == true)
    }

    @Test func fidelity() {
        #expect(ProofFidelity("login_required").needsSignIn)
        #expect(ProofFidelity("blocked").needsSignIn)
        #expect(!ProofFidelity("merchant_page").needsSignIn)
        #expect(ProofFidelity("unverified_page").isKept)
        #expect(!ProofFidelity("link_failed").isKept)
    }
}

@Suite struct SignInCheckTests {
    @Test(arguments: [
        ("https://www.amazon.com/ap/signin?openid=x", true),
        ("https://auth.uber.com/login", true),
        ("https://id.heroku.com/log-in", true),
        ("https://login.microsoftonline.com/common", true),
        ("https://www.amazon.com/gp/css/summary/print.html?orderID=1", false),
        ("https://riders.uber.com/trips/abc", false),
    ])
    func address(url: String, expected: Bool) {
        #expect(SignInCheck.isSignInPage(url: URL(string: url), hasPasswordField: false) == expected)
    }

    @Test func passwordField() {
        #expect(SignInCheck.isSignInPage(url: URL(string: "https://example.com/account"), hasPasswordField: true))
        #expect(!SignInCheck.isSignInPage(url: nil, hasPasswordField: false))
    }
}
