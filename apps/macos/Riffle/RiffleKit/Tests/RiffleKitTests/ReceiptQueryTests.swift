import Foundation
import Testing
@testable import RiffleKit

@Suite struct ReceiptQueryTests {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private let today = Day(year: 2026, month: 10, day: 29)
    private let merchants: Set<String> = ["amazon", "regions bank", "may designs"]

    private func parse(_ text: String) -> ReceiptFilters {
        ReceiptQuery.parse(text, today: today, merchants: merchants, calendar: Self.utc)
    }

    private func range(_ start: String, _ end: String) -> DayRange {
        DayRange(start: Day(start), end: Day(end))
    }

    @Test(arguments: [
        ("42.17", AmountRange.exact(4217)),
        ("$42.17", .exact(4217)),
        ("$42", .exact(4200)),
        ("42", .exact(4200)),
        ("$1,200", .exact(120_000)),
        ("40-60", AmountRange(min: 4000, max: 6000)),
        ("$60-$40", AmountRange(min: 4000, max: 6000)),
        ("40–60.50", AmountRange(min: 4000, max: 6050)),
        ("over 100", AmountRange(min: 10_000, max: nil)),
        ("more than 100", AmountRange(min: 10_000, max: nil)),
        (">100", AmountRange(min: 10_000, max: nil)),
        ("under 20", AmountRange(min: nil, max: 2000)),
        ("<=20", AmountRange(min: nil, max: 2000)),
        ("about 42", AmountRange(min: 4000, max: 4400)),
        ("~42", AmountRange(min: 4000, max: 4400)),
    ])
    func amounts(text: String, expected: AmountRange) {
        #expect(parse(text).amount == expected)
    }

    @Test(arguments: [
        ("2025", "2025-01-01", "2025-12-31"),
        ("march", "2026-03-01", "2026-03-31"),
        ("november", "2025-11-01", "2025-11-30"),
        ("feb 2024", "2024-02-01", "2024-02-29"),
        ("mar 3-10", "2026-03-03", "2026-03-10"),
        ("sept 9 2025", "2025-09-09", "2025-09-09"),
        ("q3", "2026-07-01", "2026-09-30"),
        ("q4 2025", "2025-10-01", "2025-12-31"),
        ("2026-03-14", "2026-03-14", "2026-03-14"),
        ("2026-09-30..2026-07-01", "2026-07-01", "2026-09-30"),
        ("last month", "2026-09-01", "2026-09-30"),
        ("this month", "2026-10-01", "2026-10-31"),
        ("last quarter", "2026-07-01", "2026-09-30"),
        ("last year", "2025-01-01", "2025-12-31"),
        ("last 30 days", "2026-09-30", "2026-10-29"),
        ("yesterday", "2026-10-28", "2026-10-28"),
    ])
    func dates(text: String, start: String, end: String) {
        #expect(parse(text).days == range(start, end))
    }

    @Test func openDateRanges() {
        #expect(parse("since march").days == DayRange(start: Day("2026-03-01"), end: nil))
        #expect(parse("until q1 2025").days == DayRange(start: nil, end: Day("2025-03-31")))
    }

    @Test func aYearIsNotAnAmount() {
        let filters = parse("2025")
        #expect(filters.amount == nil)
        #expect(filters.days == range("2025-01-01", "2025-12-31"))
    }

    @Test(arguments: ["card 6534", "x6534", "*6534", "…6534"])
    func cards(text: String) {
        #expect(parse(text).card == "6534")
    }

    @Test func kindsReplaceTheDefault() {
        #expect(parse("refunds").kinds == [.refund])
        #expect(parse("orders shipping").kinds == [.order, .shipping])
        #expect(parse("toner").kinds == ReceiptFilters.defaultKinds)
    }

    @Test func merchantsAndWords() {
        let filters = parse("Regions Bank checking 40-60 q3")
        #expect(filters.merchant == "regions bank")
        #expect(filters.words == "checking")
        #expect(filters.amount == AmountRange(min: 4000, max: 6000))
        #expect(filters.days == range("2026-07-01", "2026-09-30"))

        let unknown = parse("toner amazon")
        #expect(unknown.merchant == nil)
        #expect(unknown.words == "toner amazon")
    }

    @Test func quotedMerchantIsNotAMonth() {
        let filters = parse("\"may designs\"")
        #expect(filters.merchant == "may designs")
        #expect(filters.days == nil)
    }

    @Test(arguments: [
        ReceiptFilters(),
        ReceiptFilters(kinds: [.refund, .shipping], merchant: "amazon", words: "toner", amount: .exact(4217), days: DayRange(start: Day("2026-07-01"), end: Day("2026-09-30")), card: "6534"),
        ReceiptFilters(merchant: "may designs", amount: AmountRange(min: 4000, max: 6000), days: DayRange(start: Day("2026-03-01"), end: Day("2026-03-31"))),
        ReceiptFilters(amount: AmountRange(min: 10_000, max: nil), days: DayRange(start: Day("2025-01-01"), end: Day("2025-12-31"))),
        ReceiptFilters(amount: AmountRange(min: nil, max: 2050), days: DayRange(start: Day("2026-03-03"), end: Day("2026-03-17"))),
        ReceiptFilters(days: DayRange(start: Day("2026-03-14"), end: nil)),
        ReceiptFilters(days: DayRange(start: Day("2026-03-14"), end: Day("2026-03-14"))),
    ])
    func textRoundTrips(filters: ReceiptFilters) {
        let names = ["amazon": "Amazon.com", "may designs": "May Designs"]
        let text = ReceiptQuery.text(for: filters, merchantName: filters.merchant.flatMap { names[$0] }, calendar: Self.utc)
        #expect(parse(text) == filters, "\(text)")
    }

    @Test func textUsesPeriodNames() {
        let text = ReceiptQuery.text(
            for: ReceiptFilters(merchant: "amazon", amount: AmountRange(min: 4000, max: 6000), days: range("2026-07-01", "2026-09-30")),
            merchantName: "Amazon", calendar: Self.utc
        )
        #expect(text == "amazon $40-$60 q3 2026")
    }

    @Test func matches() {
        let receipt = Receipt(
            id: "m1:0", date: .now, subject: "Your order", merchant: "Amazon.com", total: 5214, paymentMethod: "Visa ending 6534",
            items: [ReceiptItem(description: "Anker Power Bank")]
        )
        let day = Day("2026-09-28")!
        #expect(ReceiptFilters(merchant: "amazon", words: "anker", amount: AmountRange(min: 4000, max: 6000), days: range("2026-09-01", "2026-09-30"), card: "6534").matches(receipt, day: day))
        #expect(ReceiptFilters(words: "\"power bank\"").matches(receipt, day: day))
        #expect(!ReceiptFilters(words: "toner").matches(receipt, day: day))
        #expect(!ReceiptFilters(amount: .exact(5200)).matches(receipt, day: day))
        #expect(!ReceiptFilters(card: "2001").matches(receipt, day: day))
        #expect(!ReceiptFilters(kinds: [.refund]).matches(receipt, day: day))
        #expect(!ReceiptFilters(days: range("2026-10-01", "2026-10-31")).matches(receipt, day: day))
    }

    @Test func sentence() {
        let parts = receiptSentence(
            ReceiptFilters(merchant: "amazon", amount: AmountRange(min: 4000, max: 6000), days: range("2026-07-01", "2026-07-31"), card: "6534"),
            merchantName: "Amazon", cardName: "Visa 6534", calendar: Self.utc
        )
        #expect(parts == [
            .token(.kinds, "Orders, subscriptions, and refunds"),
            .words("from"), .token(.merchant, "Amazon"),
            .words(", for"), .token(.amount, "$40.00 to $60.00"),
            .words(", in"), .token(.days, "July 2026"),
            .words(", paid with"), .token(.card, "Visa 6534"),
            .words("."),
        ])
    }

    @Test func sentenceWords() {
        let words = receiptSentenceWords([.token(.kinds, "Refunds"), .words("from"), .token(.merchant, "Amazon"), .words(", for"), .token(.amount, "$1.00"), .words(".")])
        #expect(words.map(\.text) == ["Refunds", "from", "Amazon", ",", "for", "$1.00", "."])
        #expect(words.map(\.attached) == [false, false, false, true, false, false, true])
        #expect(words.map(\.field) == [.kinds, nil, .merchant, nil, nil, .amount, nil])
    }

    @Test func sentenceWithoutFilters() {
        let parts = receiptSentence(ReceiptFilters(kinds: [.refund]), merchantName: nil, cardName: nil, calendar: Self.utc)
        #expect(parts == [
            .token(.kinds, "Refunds"),
            .words("from"), .token(.merchant, "any merchant"),
            .words(", for"), .token(.amount, "any amount"),
            .words(", at"), .token(.days, "any time"),
            .words(", paid with"), .token(.card, "any card"),
            .words("."),
        ])
    }
}
