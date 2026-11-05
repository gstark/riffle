import Foundation
import Testing
@testable import RiffleKit

@Suite struct ReceiptModelsTests {
    @Test(arguments: [
        ("Visa ending 6534", "Visa", "6534"),
        ("Credit card ending in 6534", nil, "6534"),
        ("American Express ••••2001", "Amex", "2001"),
        ("AMEX 2001 (Contactless)", "Amex", "2001"),
        ("Regions Bank, Business Checking, XXXXXX0402", nil, "0402"),
        ("Apple Pay", "Apple Pay", nil),
    ] as [(String, String?, String?)])
    func cards(method: String, brand: String?, last4: String?) {
        #expect(Card(method) == Card(brand: brand, last4: last4))
    }

    @Test func noCard() {
        #expect(Card("Link") == nil)
        #expect(Card(nil) == nil)
    }

    @Test func cardNames() {
        #expect(Card(brand: "Visa", last4: "6534").name == "Visa 6534")
        #expect(Card(brand: nil, last4: "6534").name == "Card 6534")
    }

    @Test func merchantKeys() {
        #expect(Merchant.key("Amazon.com") == "amazon")
        #expect(Merchant.key(" Acme, Inc. ") == "acme")
        #expect(Merchant.key("DNSimple") == "dnsimple")
    }

    @Test func money() {
        #expect(Money.format(5214, currency: "USD") == "$52.14")
        #expect(Money.format(-4999, currency: nil) == "($49.99)")
        #expect(Money.format(1500, currency: "JPY") == "¥1,500")
        #expect(Money.plain(-4999, currency: "USD") == "-49.99")
        #expect(Money.plain(5200, currency: "USD") == "52")
    }

    @Test func dayUsesThePurchaseDate() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(Receipt(id: "a", date: date, purchaseDate: "2026-09-28").day(calendar: ReceiptQueryTests.utc) == Day("2026-09-28"))
        #expect(Receipt(id: "a", date: date, purchaseDate: "Sept 28").day(calendar: ReceiptQueryTests.utc) == Day(date, calendar: ReceiptQueryTests.utc))
    }

    @Test func decodes() throws {
        let json = """
        {"receipts": [{
          "id": "m1:0", "gmailUrl": "https://mail.google.com/mail/#all/t1", "date": "2026-09-28T15:00:00.000Z",
          "kind": "refund", "subject": "Your refund", "merchant": "Amazon", "orderId": null, "purchaseDate": "2026-09-28",
          "currency": "USD", "total": 4999, "subtotal": null, "tax": 350, "shippingCost": null, "discount": null,
          "paymentMethod": "Visa ending 6534",
          "items": [{"description": "MX Keys", "quantity": 1, "unitPrice": 4999, "total": 4999}],
          "plan": null, "periodStart": null, "periodEnd": null, "proof": "email", "hasEmailPdf": true
        }]}
        """
        let response = HTTPURLResponse(url: URL(string: "https://search.example.com/receipts")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        struct Body: Decodable { let receipts: [Receipt] }
        let receipt = try #require(try HTTPSearchService.decode(Body.self, from: Data(json.utf8), response: response).receipts.first)
        #expect(receipt.kind == .refund)
        #expect(receipt.signedTotal == -4999)
        #expect(receipt.items == [ReceiptItem(description: "MX Keys", quantity: 1, unitPrice: 4999, total: 4999)])
        #expect(receipt.proof == .email)
        #expect(receipt.hasEmailPdf)
        #expect(receipt.messageId == "m1")
    }
}
