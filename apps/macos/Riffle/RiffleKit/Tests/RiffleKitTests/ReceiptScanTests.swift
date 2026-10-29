import Foundation
import Testing
@testable import RiffleKit

// The same cases as amountTexts and showsReceipt in src/receipts/proof.test.ts.
@Suite struct ReceiptScanTests {
    private func receipt(total: Int?, currency: String? = "USD", orderId: String? = nil) -> PendingReceipt {
        PendingReceipt(
            id: "a:0", messageId: "a", date: .now, subject: "Receipt", merchant: "Shop", orderId: orderId,
            total: total, currency: currency, url: nil, printUrl: URL(string: "https://shop.example/a")!
        )
    }

    @Test(arguments: [
        (123456, "USD", ["1234.56", "1,234.56", "1234,56", "1.234,56", "1 234,56"]),
        (1390, "USD", ["13.90", "13,90"]),
        (6500, "USD", ["65.00", "65,00", "$65"]),
        (123400, "EUR", ["1234.00", "1,234.00", "1234,00", "1.234,00", "1 234,00", "€1,234"]),
        (1500, "JPY", ["1500", "1,500", "1.500", "1 500"]),
    ] as [(Int, String, [String])])
    func amountTexts(minor: Int, currency: String, expected: [String]) {
        #expect(ReceiptScan.amountTexts(minor: minor, currency: currency) == expected)
    }

    @Test func amountTextsWithoutACurrency() {
        #expect(ReceiptScan.amountTexts(minor: 999, currency: nil) == ["9.99", "9,99"])
    }

    @Test(arguments: [
        ("Order total: $1,234.56", 123456),
        ("Gesamt: 1.234,56 €", 123456),
        ("Total 1\u{00A0}234,56", 123456),
        ("You paid $1,234 today", 123400),
        ("Total\n$44\n.12\nPaid", 4412),
        ("Total $\n1,234.56", 123456),
    ])
    func findsTheAmount(text: String, total: Int) {
        #expect(ReceiptScan.shows(receipt(total: total), in: text))
    }

    @Test(arguments: [
        ("Total: $11,234.56", 123456),
        ("Total: 1234.567", 123456),
        ("Total: $1,234.99", 123400),
        ("Total: $1,234 .99", 123400),
        ("Help center", 123456),
    ])
    func doesNotFindTheAmount(text: String, total: Int) {
        #expect(!ReceiptScan.shows(receipt(total: total), in: text))
    }

    @Test func findsOneOfSeveralOrderIds() {
        #expect(ReceiptScan.shows(receipt(total: nil, orderId: "111-0, 222-1"), in: "Order #222-1"))
    }

    @Test func ignoresShortOrderIds() {
        #expect(!ReceiptScan.shows(receipt(total: nil, currency: nil, orderId: "12"), in: "Item 12 of 30"))
    }
}
