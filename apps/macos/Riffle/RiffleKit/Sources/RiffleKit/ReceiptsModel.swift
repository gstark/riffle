// The state of the Receipts window: all receipts, the filters, and the receipts that match them.
// Riffle loads all receipts once and filters them on the Mac, so a filter change shows the results at once.

import Foundation
import Observation

@MainActor @Observable
public final class ReceiptsModel {
    public enum LoadState: Equatable, Sendable {
        case notLoaded, loading, loaded
        case failed(SearchError)
    }

    /// A merchant or a card in a filter menu.
    public struct Option: Identifiable, Hashable, Sendable {
        /// The `Merchant.key`, or the last four digits of the card
        public let id: String
        public let name: String
        /// The number of receipts
        public let count: Int
    }

    /// An amount in one currency.
    public struct Amount: Equatable, Sendable {
        public let currency: String
        /// Minor units. Negative when the refunds are more than the charges.
        public let minor: Int

        public init(currency: String, minor: Int) {
            self.currency = currency
            self.minor = minor
        }

        public var text: String { Money.format(minor, currency: currency) }
    }

    /// A merchant or a month in the sidebar, with the receipts that match the other filters.
    public struct Group: Identifiable, Equatable, Sendable {
        /// The `Merchant.key`, or the `Month.id`
        public let id: String
        public let name: String
        /// The number of receipts
        public let count: Int
        /// Charges minus refunds, for each currency
        public let net: [Amount]

        public init(id: String, name: String, count: Int, net: [Amount]) {
            self.id = id
            self.name = name
            self.count = count
            self.net = net
        }
    }

    /// The results of one month, newest month first.
    public struct Month: Identifiable, Equatable, Sendable {
        public let year: Int
        public let month: Int
        /// For example "September 2026".
        public let title: String
        public let receipts: [Receipt]
        /// Charges minus refunds, for each currency
        public let net: [Amount]

        public var id: String { "\(year)-\(month)" }
    }

    public struct Summary: Equatable, Sendable {
        public let count: Int
        public let refunds: Int
        /// Charges minus refunds, for each currency
        public let net: [Amount]
        public let tax: [Amount]
    }

    public private(set) var load: LoadState = .notLoaded
    public private(set) var receipts: [Receipt] = []
    /// The text in the search field. A token edit writes the text of the new filters.
    public private(set) var query = ""
    public private(set) var filters = ReceiptFilters()
    /// The receipts that match the filters, newest first
    public private(set) var results: [Receipt] = []
    public private(set) var months: [Month] = []
    public private(set) var summary = Summary(count: 0, refunds: 0, net: [], tax: [])
    /// The merchants of all receipts, most receipts first
    public private(set) var merchants: [Option] = []
    /// The cards of all receipts, most receipts first
    public private(set) var cards: [Option] = []
    /// The merchants of the receipts that match the filters without the merchant filter, most receipts first.
    /// The sidebar shows them, so a merchant stays in the list while it is selected.
    public private(set) var merchantGroups: [Group] = []
    /// The months of the receipts that match the filters without the days filter, newest first.
    public private(set) var monthGroups: [Group] = []
    public var selection: Receipt.ID?

    private let store: any ConnectionStore
    private let makeService: (Connection) -> any ReceiptsService
    private let calendar: Calendar
    private let now: () -> Date
    /// `Receipt.day()` of each receipt, by ID.
    @ObservationIgnored private var days: [Receipt.ID: Day] = [:]

    public init(
        store: any ConnectionStore,
        makeService: @escaping (Connection) -> any ReceiptsService = { HTTPReceiptsService(connection: $0) },
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.makeService = makeService
        self.calendar = calendar
        self.now = now
    }

    /// The selected receipt. It can be a related receipt that the filters hide, for example a shipping notice.
    public var selected: Receipt? {
        receipts.first { $0.id == selection }
    }

    /// The `Group.id` of the month that the days filter shows. Nil when the filter is not exactly one month.
    public var selectedMonth: String? {
        monthGroups.first { monthRange($0.id) == filters.days }?.id
    }

    /// The day of a receipt: its purchase date, or the day of its email.
    public func day(of receipt: Receipt) -> Day {
        days[receipt.id] ?? receipt.day(calendar: calendar)
    }

    public func merchantName(_ key: String?) -> String? {
        merchants.first { $0.id == key }?.name
    }

    public func cardName(_ last4: String?) -> String? {
        cards.first { $0.id == last4 }?.name
    }

    /// True when an exact amount found nothing. Then the window offers the amounts near it.
    public var canWidenAmount: Bool {
        guard let amount = filters.amount, amount.min != nil, amount.min == amount.max else { return false }
        return results.isEmpty
    }

    /// Gets all receipts again. Keeps the filters.
    public func refresh() async {
        guard let service = store.load().map(makeService) else { return }
        load = .loading
        do {
            let receipts = try await service.receipts()
            days = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, $0.day(calendar: calendar)) })
            merchants = Self.options(receipts.compactMap { receipt in
                receipt.merchant.map { (Merchant.key($0), $0) }
            })
            cards = Self.options(receipts.compactMap { receipt in
                receipt.card.flatMap { card in card.last4.map { ($0, card.name) } }
            })
            self.receipts = receipts.sorted { (day(of: $0), $0.date) > (day(of: $1), $1.date) }
            load = .loaded
            // The text can name a merchant that was not known before the load.
            if !query.isEmpty { filters = parse(query) }
            apply()
        } catch {
            load = .failed(error as? SearchError ?? .server)
        }
    }

    /// Reads the search text.
    public func setQuery(_ text: String) {
        query = text
        filters = parse(text)
        apply()
    }

    /// Sets the filters from a token editor, and writes their text in the search field.
    public func setFilters(_ filters: ReceiptFilters) {
        self.filters = filters
        query = ReceiptQuery.text(for: filters, merchantName: merchantName(filters.merchant), calendar: calendar)
        apply()
    }

    /// Shows one merchant, by its `Merchant.key`. Nil shows all merchants.
    public func select(merchant key: String?) {
        var filters = filters
        filters.merchant = key
        setFilters(filters)
    }

    /// Shows one month, by its `Group.id`. Nil shows all months.
    public func select(month id: String?) {
        var filters = filters
        filters.days = id.flatMap(monthRange)
        setFilters(filters)
    }

    /// The other receipts of the same email, and the receipts of the same order, for example its shipping notice.
    public func related(to receipt: Receipt) -> [Receipt] {
        receipts.filter { other in
            other.id != receipt.id
                && (other.messageId == receipt.messageId || (receipt.orderId != nil && other.orderId == receipt.orderId))
        }
    }

    /// Shows the amounts near the exact amount, for a charge with a tip or a currency conversion.
    public func widenAmount() {
        guard let exact = filters.amount?.min else { return }
        var widened = filters
        widened.amount = AmountRange(min: max(0, exact - ReceiptFilters.nearTolerance), max: exact + ReceiptFilters.nearTolerance)
        setFilters(widened)
    }

    public func pdfURL(for receipt: Receipt, which: PdfChoice = .best) async throws -> URL {
        guard let service = store.load().map(makeService) else { throw SearchError.unauthorized }
        return try await service.pdfURL(id: receipt.id, which: which)
    }

    /// The results as a CSV file for a spreadsheet. A refund has a negative amount and tax.
    public func csv() -> String {
        let header = ["Date", "Merchant", "Kind", "Amount", "Currency", "Tax", "Card", "Order ID", "Subject", "Email"]
        let rows = results.map { receipt in
            [
                day(of: receipt).text,
                receipt.merchant ?? "",
                receipt.kind.rawValue,
                receipt.signedTotal.map { Money.plain($0, currency: receipt.currency) } ?? "",
                receipt.currency ?? "",
                receipt.signedTax.map { Money.plain($0, currency: receipt.currency) } ?? "",
                receipt.card?.name ?? receipt.paymentMethod ?? "",
                receipt.orderId ?? "",
                receipt.subject,
                receipt.gmailUrl.absoluteString,
            ]
        }
        return ([header] + rows).map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Private

    private func parse(_ text: String) -> ReceiptFilters {
        ReceiptQuery.parse(text, today: Day(now(), calendar: calendar), merchants: Set(merchants.map(\.id)), calendar: calendar)
    }

    private func apply() {
        results = receipts.filter { filters.matches($0, day: day(of: $0)) }
        months = monthsOf(results)

        var withoutMerchant = filters
        withoutMerchant.merchant = nil
        merchantGroups = Self.merchantGroups(receipts.filter { withoutMerchant.matches($0, day: day(of: $0)) })
        var withoutDays = filters
        withoutDays.days = nil
        monthGroups = monthsOf(receipts.filter { withoutDays.matches($0, day: day(of: $0)) })
            .map { Group(id: $0.id, name: $0.title, count: $0.receipts.count, net: $0.net) }

        summary = Summary(
            count: results.count,
            refunds: results.count(where: { $0.kind == .refund }),
            net: Self.sum(results, \.signedTotal),
            tax: Self.sum(results, \.signedTax)
        )
        if selection == nil || !results.contains(where: { $0.id == selection }) { selection = results.first?.id }
    }

    /// Groups receipts that are sorted newest first by their month.
    private func monthsOf(_ receipts: [Receipt]) -> [Month] {
        var groups: [(year: Int, month: Int, receipts: [Receipt])] = []
        for receipt in receipts {
            let day = day(of: receipt)
            if groups.last?.year == day.year, groups.last?.month == day.month {
                groups[groups.count - 1].receipts.append(receipt)
            } else {
                groups.append((day.year, day.month, [receipt]))
            }
        }
        return groups.map { group in
            let name = calendar.standaloneMonthSymbols[group.month - 1]
            return Month(year: group.year, month: group.month, title: "\(name) \(group.year)", receipts: group.receipts, net: Self.sum(group.receipts, \.signedTotal))
        }
    }

    /// The days of a month `Group.id`, for example "2026-9".
    private func monthRange(_ id: String) -> DayRange? {
        let parts = id.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        return ReceiptQuery.monthRange(parts[1], year: parts[0], calendar: calendar)
    }

    /// One group for each merchant, with the most frequent name of the merchant. Most receipts first.
    private static func merchantGroups(_ receipts: [Receipt]) -> [Group] {
        var byKey: [String: [Receipt]] = [:]
        for receipt in receipts {
            if let key = receipt.merchantKey, !key.isEmpty { byKey[key, default: []].append(receipt) }
        }
        return byKey
            .map { key, receipts in
                var names: [String: Int] = [:]
                for name in receipts.compactMap(\.merchant) { names[name, default: 0] += 1 }
                let name = names.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
                return Group(id: key, name: name, count: receipts.count, net: sum(receipts, \.signedTotal))
            }
            .sorted { ($1.count, $0.name.lowercased()) < ($0.count, $1.name.lowercased()) }
    }

    /// The sum for each currency. USD first, then the other currencies by name. A missing currency counts as USD.
    private static func sum(_ receipts: [Receipt], _ amount: (Receipt) -> Int?) -> [Amount] {
        var sums: [String: Int] = [:]
        for receipt in receipts {
            guard let value = amount(receipt) else { continue }
            sums[receipt.currency ?? "USD", default: 0] += value
        }
        return sums
            .sorted { ($0.key == "USD" ? "" : $0.key) < ($1.key == "USD" ? "" : $1.key) }
            .map { Amount(currency: $0.key, minor: $0.value) }
    }

    /// One option for each key, with the most frequent name of the key. Most receipts first.
    private static func options(_ pairs: [(key: String, name: String)]) -> [Option] {
        var names: [String: [String: Int]] = [:]
        for (key, name) in pairs where !key.isEmpty {
            names[key, default: [:]][name, default: 0] += 1
        }
        return names
            .map { key, counts in
                let name = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? key
                return Option(id: key, name: name, count: counts.values.reduce(0, +))
            }
            .sorted { ($1.count, $0.name.lowercased()) < ($0.count, $1.name.lowercased()) }
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
