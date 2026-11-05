import Foundation
import Testing
@testable import RiffleKit

actor FakeReceiptsService: ReceiptsService {
    let all: [Receipt]
    let error: SearchError?

    init(_ all: [Receipt] = [], error: SearchError? = nil) {
        self.all = all
        self.error = error
    }

    func receipts() async throws -> [Receipt] {
        if let error { throw error }
        return all
    }

    func pdfURL(id: String, which: PdfChoice) async throws -> URL {
        URL(string: "https://archive.example.com/\(id)\(which == .email ? "-email" : "").pdf")!
    }
}

@MainActor @Suite struct ReceiptsModelTests {
    private static func receipt(
        _ id: String, _ day: String, _ merchant: String, _ total: Int, kind: ReceiptKind = .order, tax: Int? = nil,
        card: String? = "Visa ending 6534", currency: String? = "USD"
    ) -> Receipt {
        Receipt(
            id: id, date: Day(day)!.date(calendar: ReceiptQueryTests.utc), kind: kind, subject: "Subject, \"\(id)\"",
            merchant: merchant, purchaseDate: day, currency: currency, total: total, tax: tax, paymentMethod: card
        )
    }

    private static let sample = [
        receipt("a", "2026-07-14", "Amazon", 4107, tax: 300),
        receipt("b", "2026-09-28", "Amazon.com", 5214, tax: 338),
        receipt("c", "2026-08-22", "Amazon", 4999, kind: .refund, tax: 350),
        receipt("d", "2026-08-09", "Amazon", 4999, tax: 350, card: "Card ending 6534"),
        receipt("e", "2026-09-01", "Netflix", 1549, card: "AMEX 2001"),
        receipt("f", "2026-09-02", "Amazon", 0, kind: .shipping),
        receipt("g", "2026-09-03", "Hotel Lisboa", 12_000, currency: "EUR"),
    ]

    private func model(_ receipts: [Receipt] = sample, error: SearchError? = nil, connected: Bool = true) async -> ReceiptsModel {
        let model = ReceiptsModel(
            store: MemoryConnectionStore(connected ? .sample : nil),
            makeService: { _ in FakeReceiptsService(receipts, error: error) },
            calendar: ReceiptQueryTests.utc,
            now: { Day("2026-10-29")!.date(calendar: ReceiptQueryTests.utc) }
        )
        await model.refresh()
        return model
    }

    @Test func loadsAndHidesShippingNotices() async {
        let model = await model()
        #expect(model.load == .loaded)
        #expect(model.results.map(\.id) == ["b", "g", "e", "c", "d", "a"])
        #expect(model.selection == "b")
    }

    @Test func groupsByMonthWithNetTotals() async {
        let model = await model()
        model.setQuery("amazon")
        #expect(model.months.map(\.title) == ["September 2026", "August 2026", "July 2026"])
        #expect(model.months[1].net == [ReceiptsModel.Amount(currency: "USD", minor: 0)])
        #expect(model.summary == ReceiptsModel.Summary(
            count: 4, refunds: 1,
            net: [ReceiptsModel.Amount(currency: "USD", minor: 9321)],
            tax: [ReceiptsModel.Amount(currency: "USD", minor: 638)]
        ))
    }

    @Test func sumsEachCurrency() async {
        let model = await model()
        model.setQuery("q3")
        #expect(model.summary.net.map(\.currency) == ["USD", "EUR"])
    }

    @Test func groupsForTheSidebar() async {
        let model = await model()
        #expect(model.merchantGroups == [
            ReceiptsModel.Group(id: "amazon", name: "Amazon", count: 4, net: [ReceiptsModel.Amount(currency: "USD", minor: 9321)]),
            ReceiptsModel.Group(id: "hotel lisboa", name: "Hotel Lisboa", count: 1, net: [ReceiptsModel.Amount(currency: "EUR", minor: 12_000)]),
            ReceiptsModel.Group(id: "netflix", name: "Netflix", count: 1, net: [ReceiptsModel.Amount(currency: "USD", minor: 1549)]),
        ])
        #expect(model.monthGroups.map(\.name) == ["September 2026", "August 2026", "July 2026"])
        #expect(model.monthGroups.map(\.count) == [3, 2, 1])

        // The merchant list ignores the merchant filter, and the month list ignores the days filter.
        model.select(merchant: "amazon")
        #expect(model.query == "amazon")
        #expect(model.merchantGroups.count == 3)
        #expect(model.monthGroups.map(\.count) == [1, 2, 1])

        model.select(month: "2026-8")
        #expect(model.selectedMonth == "2026-8")
        #expect(model.query == "amazon august 2026")
        #expect(model.results.map(\.id) == ["c", "d"])
        #expect(model.monthGroups.map(\.count) == [1, 2, 1])
        #expect(model.merchantGroups.map(\.id) == ["amazon"])

        model.select(month: nil)
        #expect(model.selectedMonth == nil)
        #expect(model.results.count == 4)
    }

    @Test func relatedReceipts() async {
        let date = Day("2026-09-01")!.date(calendar: ReceiptQueryTests.utc)
        let order = Receipt(id: "m1:0", date: date, merchant: "Amazon", orderId: "112-1", total: 100)
        let second = Receipt(id: "m1:1", date: date, merchant: "Amazon", orderId: "112-2", total: 200)
        let shipped = Receipt(id: "m2:0", date: date, kind: .shipping, merchant: "Amazon", orderId: "112-1")
        let other = Receipt(id: "m3:0", date: date, merchant: "Netflix", total: 1549)
        let model = await model([order, second, shipped, other])

        #expect(Set(model.related(to: order).map(\.id)) == ["m1:1", "m2:0"])
        #expect(model.related(to: other).isEmpty)

        // A related receipt that the filters hide can be selected.
        model.selection = "m2:0"
        #expect(model.selected?.kind == .shipping)
    }

    @Test func groupsMerchantsAndCards() async {
        let model = await model()
        #expect(model.merchants.first == ReceiptsModel.Option(id: "amazon", name: "Amazon", count: 5))
        #expect(model.cards.map(\.id) == ["6534", "2001"])
        #expect(model.cardName("6534") == "Visa 6534")
    }

    @Test func tokenEditsWriteTheText() async {
        let model = await model()
        model.setFilters(ReceiptFilters(merchant: "amazon", amount: AmountRange(min: 4000, max: 6000)))
        #expect(model.query == "amazon $40-$60")
        #expect(model.results.map(\.id) == ["b", "c", "d", "a"])
    }

    @Test func widensAnExactAmount() async {
        let model = await model()
        model.setQuery("52.00")
        #expect(model.results.isEmpty)
        #expect(model.canWidenAmount)

        model.widenAmount()
        #expect(model.results.map(\.id) == ["b"])
        #expect(!model.canWidenAmount)
    }

    @Test func keepsTheSelectionInTheResults() async {
        let model = await model()
        model.selection = "e"
        model.setQuery("netflix")
        #expect(model.selection == "e")
        model.setQuery("refunds")
        #expect(model.selection == "c")
        model.setQuery("toner")
        #expect(model.selection == nil)
    }

    @Test func csv() async {
        let model = await model()
        model.setQuery("refunds")
        #expect(model.csv() == [
            "Date,Merchant,Kind,Amount,Currency,Tax,Card,Order ID,Subject,Email",
            #"2026-08-22,Amazon,refund,-49.99,USD,-3.5,Visa 6534,,"Subject, ""c""",https://mail.google.com/"#,
            "",
        ].joined(separator: "\r\n"))
    }

    @Test func failedLoad() async {
        let model = await model(error: .unauthorized)
        #expect(model.load == .failed(.unauthorized))
    }

    @Test func noConnection() async {
        let model = await model(connected: false)
        #expect(model.load == .notLoaded)
    }

    @Test func pdfURL() async throws {
        let model = await model()
        let best = try await model.pdfURL(for: Self.sample[0])
        let email = try await model.pdfURL(for: Self.sample[0], which: .email)
        #expect(best.absoluteString == "https://archive.example.com/a.pdf")
        #expect(email.absoluteString == "https://archive.example.com/a-email.pdf")
    }
}
