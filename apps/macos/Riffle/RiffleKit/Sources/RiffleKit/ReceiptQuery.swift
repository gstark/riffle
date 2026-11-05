// The filters of the Receipts window, and the search text that sets them. Riffle reads the text on the Mac, without
// Claude, for example "amazon 40-60 q3" or "card 6534 over 100 last month".

import Foundation

/// An inclusive range of amounts in minor units. Nil ends are open.
public struct AmountRange: Equatable, Sendable {
    public var min: Int?
    public var max: Int?

    public init(min: Int?, max: Int?) {
        self.min = min
        self.max = max
    }

    public static func exact(_ amount: Int) -> AmountRange { AmountRange(min: amount, max: amount) }

    public func contains(_ amount: Int) -> Bool {
        (min.map { amount >= $0 } ?? true) && (max.map { amount <= $0 } ?? true)
    }
}

/// An inclusive range of days. Nil ends are open.
public struct DayRange: Equatable, Sendable {
    public var start: Day?
    public var end: Day?

    public init(start: Day?, end: Day?) {
        self.start = start
        self.end = end
    }

    public func contains(_ day: Day) -> Bool {
        (start.map { day >= $0 } ?? true) && (end.map { day <= $0 } ?? true)
    }
}

public struct ReceiptFilters: Equatable, Sendable {
    /// Shipping notices repeat their orders, so they are not in the default kinds.
    public static let defaultKinds: Set<ReceiptKind> = [.order, .subscription, .refund]

    public var kinds: Set<ReceiptKind>
    /// A `Merchant.key`
    public var merchant: String?
    /// Words that the merchant, the subject, an item, or the order ID must contain
    public var words: String
    public var amount: AmountRange?
    public var days: DayRange?
    /// The last four digits of the card
    public var card: String?

    public init(
        kinds: Set<ReceiptKind> = defaultKinds, merchant: String? = nil, words: String = "", amount: AmountRange? = nil,
        days: DayRange? = nil, card: String? = nil
    ) {
        self.kinds = kinds
        self.merchant = merchant
        self.words = words
        self.amount = amount
        self.days = days
        self.card = card
    }

    /// The amounts within this many minor units of an exact amount, for a charge with a tip or a currency conversion.
    public static let nearTolerance = 200

    /// `day` is `receipt.day()`. The caller gives it, because it is slow to get for each search.
    public func matches(_ receipt: Receipt, day: Day) -> Bool {
        guard kinds.contains(receipt.kind) else { return false }
        if let merchant, receipt.merchantKey != merchant { return false }
        if let card, receipt.card?.last4 != card { return false }
        if let amount {
            guard let total = receipt.total, amount.contains(total) else { return false }
        }
        if let days, !days.contains(day) { return false }
        if !words.isEmpty {
            let haystack = ([receipt.merchant, receipt.subject, receipt.orderId, receipt.plan].compactMap { $0 }
                + receipt.items.map(\.description)).joined(separator: "\n")
            for word in ReceiptQuery.phrases(words) where haystack.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return true
    }
}

// MARK: - Parse

public enum ReceiptQuery {
    private static let kindWords: [String: ReceiptKind] = [
        "order": .order, "orders": .order, "purchase": .order, "purchases": .order,
        "subscription": .subscription, "subscriptions": .subscription, "renewal": .subscription, "renewals": .subscription,
        "refund": .refund, "refunds": .refund, "return": .refund, "returns": .refund,
        "shipping": .shipping, "shipment": .shipping, "shipments": .shipping,
    ]
    private static let lowerWords: Set<String> = ["over", "above", "min", ">", ">="]
    private static let upperWords: Set<String> = ["under", "below", "max", "<", "<="]
    private static let nearWords: Set<String> = ["about", "around", "near", "~"]
    static let monthNames = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november",
        "december",
    ]

    /// Reads the search text. `merchants` maps each `Merchant.key` to nothing in particular: only the keys matter.
    /// Words that name a merchant set the merchant filter. Other words that are not filters must be in the receipt.
    public static func parse(
        _ text: String, today: Day, merchants: Set<String> = [], calendar: Calendar = .current
    ) -> ReceiptFilters {
        var filters = ReceiptFilters()
        var kinds: Set<ReceiptKind> = []
        var rest: [String] = []
        let tokens = tokenize(text)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil

            if let kind = kindWords[token] {
                kinds.insert(kind)
                index += 1
            } else if token == "card", let next, let last4 = cardDigits(next) {
                filters.card = last4
                index += 2
            } else if let last4 = cardDigits(token), token.first.map({ "x*…#".contains($0) }) == true {
                filters.card = last4
                index += 1
            } else if let (range, used) = dateRange(tokens, index, today: today, calendar: calendar) {
                filters.days = range
                index += used
            } else if let (range, used) = amountRange(tokens, index) {
                filters.amount = range
                index += used
            } else {
                rest.append(token)
                index += 1
            }
        }

        if !kinds.isEmpty { filters.kinds = kinds }
        // The longest run of words at the start that names a merchant.
        for count in stride(from: rest.count, through: 1, by: -1) {
            let key = Merchant.key(rest.prefix(count).joined(separator: " "))
            if merchants.contains(key) {
                filters.merchant = key
                rest.removeFirst(count)
                break
            }
        }
        filters.words = rest.joined(separator: " ")
        return filters
    }

    /// Lower-case words. A phrase in quotes is one word, with its quotes: "\"regions bank\"".
    /// A word with "-" between two amounts stays one word: "40-60".
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        let normal = text.lowercased()
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        let characters = Array(normal)
        for (index, character) in characters.enumerated() {
            // A comma between digits groups the digits of an amount, as in "$1,200".
            let groupsDigits = character == "," && index > 0 && index + 1 < characters.count
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            if character == "\"" {
                current.append(character)
                quoted.toggle()
            } else if !quoted, !groupsDigits, character.isWhitespace || character == "," {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// The words or quoted phrases of `words`, without quotes.
    static func phrases(_ words: String) -> [String] {
        tokenize(words).map { $0.replacingOccurrences(of: "\"", with: "") }.filter { !$0.isEmpty }
    }

    private static func cardDigits(_ token: String) -> String? {
        let digits = token.trimmingCharacters(in: CharacterSet(charactersIn: "x*…#"))
        return digits.count == 4 && digits.allSatisfy({ $0.isASCII && $0.isNumber }) ? digits : nil
    }

    // MARK: Amounts

    /// An amount in cents, for example "$42.17", "42.17", "42", or "$1,200". Not a year such as "2026".
    static func amount(_ token: String, allowYear: Bool = false) -> Int? {
        let hasDollar = token.hasPrefix("$")
        let text = token.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              text.filter({ $0 == "." }).count <= 1, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        if !hasDollar, !allowYear, !text.contains("."), let whole = Int(text), (1990...2099).contains(whole) { return nil }
        if let dot = text.firstIndex(of: "."), text[text.index(after: dot)...].count > 2 { return nil }
        return NSDecimalNumber(decimal: value * 100).intValue
    }

    private static func amountRange(_ tokens: [String], _ index: Int) -> (AmountRange, Int)? {
        let token = tokens[index]
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil

        // "40-60" or "$40-$60"
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 2, let low = amount(String(parts[0]), allowYear: true), let high = amount(String(parts[1]), allowYear: true) {
            return (AmountRange(min: Swift.min(low, high), max: Swift.max(low, high)), 1)
        }
        // ">100", "<20", "~42"
        let comparators: [(String, (Int) -> AmountRange)] = [
            (">", { AmountRange(min: $0, max: nil) }), ("<", { AmountRange(min: nil, max: $0) }), ("~", near),
        ]
        for (prefix, make) in comparators where token.hasPrefix(prefix) && token.count > prefix.count {
            if let value = amount(String(token.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "=")), allowYear: true) {
                return (make(value), 1)
            }
        }
        // "over 100", "under 20", "about 42", "more than 100", "less than 20"
        var word = token
        var used = 1
        if (token == "more" || token == "less"), next == "than" {
            word = token == "more" ? "over" : "under"
            used = 2
        }
        if index + used < tokens.count, let value = amount(tokens[index + used], allowYear: true) {
            if lowerWords.contains(word) { return (AmountRange(min: value, max: nil), used + 1) }
            if upperWords.contains(word) { return (AmountRange(min: nil, max: value), used + 1) }
            if nearWords.contains(word) { return (near(value), used + 1) }
        }
        if let value = amount(token) { return (.exact(value), 1) }
        return nil
    }

    private static func near(_ value: Int) -> AmountRange {
        AmountRange(min: Swift.max(0, value - ReceiptFilters.nearTolerance), max: value + ReceiptFilters.nearTolerance)
    }

    // MARK: Dates

    private static func dateRange(_ tokens: [String], _ index: Int, today: Day, calendar: Calendar) -> (DayRange, Int)? {
        let token = tokens[index]
        // "since march": from the start of the period. "until march": to its end.
        if token == "since" || token == "after" || token == "until" || token == "through" {
            guard index + 1 < tokens.count, let (range, used) = period(tokens, index + 1, today: today, calendar: calendar) else {
                return nil
            }
            let open = token == "since" || token == "after" ? DayRange(start: range.start, end: nil) : DayRange(start: nil, end: range.end)
            return (open, used + 1)
        }
        return period(tokens, index, today: today, calendar: calendar)
    }

    /// A day, a month, a quarter, a year, or a range of days.
    private static func period(_ tokens: [String], _ index: Int, today: Day, calendar: Calendar) -> (DayRange, Int)? {
        let token = tokens[index]
        let next = index + 1 < tokens.count ? tokens[index + 1] : nil
        let afterNext = index + 2 < tokens.count ? tokens[index + 2] : nil

        // "2026-03-14" or "2026-07-01..2026-09-30"
        if token.contains("..") {
            let parts = token.components(separatedBy: "..")
            if parts.count == 2, let start = Day(parts[0]), let end = Day(parts[1]) {
                return (DayRange(start: Swift.min(start, end), end: Swift.max(start, end)), 1)
            }
        }
        if let day = Day(token) { return (DayRange(start: day, end: day), 1) }

        // "2025"
        if let year = year(token) { return (yearRange(year, calendar: calendar), 1) }

        // "q3" or "q3 2025"
        if token.count == 2, token.hasPrefix("q"), let quarter = Int(token.dropFirst()), (1...4).contains(quarter) {
            if let next, let year = year(next) { return (quarterRange(quarter, year: year, calendar: calendar), 2) }
            let currentQuarter = (today.month - 1) / 3 + 1
            let year = quarter <= currentQuarter ? today.year : today.year - 1
            return (quarterRange(quarter, year: year, calendar: calendar), 1)
        }

        // "march", "mar 2025", "march 3", "march 3-10", "march 3 2025"
        if let month = month(token) {
            var used = 1
            var days: (Int, Int)?
            if let next, let parsed = dayNumbers(next) {
                days = parsed
                used = 2
            }
            var year: Int?
            if index + used < tokens.count, let parsed = Self.year(tokens[index + used]) {
                year = parsed
                used += 1
            }
            // Without a year: the last such month that started, so "november" in October is last November.
            let resolved = year ?? (month <= today.month ? today.year : today.year - 1)
            if let (first, last) = days {
                return (DayRange(start: Day(year: resolved, month: month, day: first), end: Day(year: resolved, month: month, day: last)), used)
            }
            return (monthRange(month, year: resolved, calendar: calendar), used)
        }

        switch (token, next) {
        case ("today", _): return (DayRange(start: today, end: today), 1)
        case ("yesterday", _):
            let day = shift(today, days: -1, calendar: calendar)
            return (DayRange(start: day, end: day), 1)
        case ("this", "month"), ("last", "month"):
            let first = token == "this" ? today : shift(Day(year: today.year, month: today.month, day: 1), days: -1, calendar: calendar)
            return (monthRange(first.month, year: first.year, calendar: calendar), 2)
        case ("this", "quarter"), ("last", "quarter"):
            var quarter = (today.month - 1) / 3 + 1
            var year = today.year
            if token == "last" {
                quarter -= 1
                if quarter == 0 { quarter = 4; year -= 1 }
            }
            return (quarterRange(quarter, year: year, calendar: calendar), 2)
        case ("this", "year"): return (yearRange(today.year, calendar: calendar), 2)
        case ("last", "year"): return (yearRange(today.year - 1, calendar: calendar), 2)
        case ("this", "week"), ("last", "week"):
            let start = shift(today, days: token == "this" ? -6 : -13, calendar: calendar)
            return (DayRange(start: start, end: token == "this" ? today : shift(today, days: -7, calendar: calendar)), 2)
        default: break
        }

        // "last 30 days" or "past 30 days"
        if token == "last" || token == "past", let next, let count = Int(next), count > 0, afterNext == "days" || afterNext == "day" {
            return (DayRange(start: shift(today, days: -(count - 1), calendar: calendar), end: today), 3)
        }
        return nil
    }

    private static func year(_ token: String) -> Int? {
        guard token.count == 4, let year = Int(token), (1990...2099).contains(year) else { return nil }
        return year
    }

    static func month(_ token: String) -> Int? {
        guard token.count >= 3 else { return nil }
        let word = token == "sept" ? "sep" : token
        return monthNames.firstIndex { $0.hasPrefix(word) }.map { $0 + 1 }
    }

    /// "3" or "3-10", the days of a month.
    private static func dayNumbers(_ token: String) -> (Int, Int)? {
        let parts = token.split(separator: "-").compactMap { Int($0) }
        guard (1...2).contains(parts.count), parts.count == token.split(separator: "-").count,
              parts.allSatisfy({ (1...31).contains($0) })
        else { return nil }
        return (parts.min()!, parts.max()!)
    }

    // MARK: Day arithmetic

    static func shift(_ day: Day, days: Int, calendar: Calendar) -> Day {
        Day(calendar.date(byAdding: .day, value: days, to: day.date(calendar: calendar)) ?? day.date(calendar: calendar), calendar: calendar)
    }

    static func lastDay(month: Int, year: Int, calendar: Calendar) -> Int {
        let first = Day(year: year, month: month, day: 1).date(calendar: calendar)
        return calendar.range(of: .day, in: .month, for: first)?.count ?? 31
    }

    static func monthRange(_ month: Int, year: Int, calendar: Calendar) -> DayRange {
        DayRange(start: Day(year: year, month: month, day: 1), end: Day(year: year, month: month, day: lastDay(month: month, year: year, calendar: calendar)))
    }

    static func quarterRange(_ quarter: Int, year: Int, calendar: Calendar) -> DayRange {
        let first = (quarter - 1) * 3 + 1
        return DayRange(start: Day(year: year, month: first, day: 1), end: monthRange(first + 2, year: year, calendar: calendar).end)
    }

    static func yearRange(_ year: Int, calendar: Calendar) -> DayRange {
        DayRange(start: Day(year: year, month: 1, day: 1), end: Day(year: year, month: 12, day: 31))
    }

    // MARK: - Text

    /// The search text that gives `filters` again with `parse`. `merchantName` is the name of `filters.merchant`.
    public static func text(for filters: ReceiptFilters, merchantName: String?, calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if filters.kinds != ReceiptFilters.defaultKinds {
            parts += ReceiptKind.allCases.filter(filters.kinds.contains).map { $0 == .shipping ? "shipping" : $0.plural }
        }
        if let merchant = filters.merchant, let merchantName {
            // Quotes keep a name such as "May Designs" from being read as a filter.
            let name = merchantName.lowercased()
            let bare = parse(name, today: Day(year: 2000, month: 1, day: 1), merchants: [merchant], calendar: calendar)
            parts.append(bare == ReceiptFilters(merchant: merchant) ? name : "\"\(name)\"")
        }
        if !filters.words.isEmpty { parts.append(filters.words) }
        if let amount = filters.amount {
            let dollars = { (minor: Int) in "$" + Money.plain(minor, currency: "USD") }
            switch (amount.min, amount.max) {
            case let (min?, max?) where min == max: parts.append(dollars(min))
            case let (min?, max?): parts.append("\(dollars(min))-\(dollars(max))")
            case let (min?, nil): parts.append("over \(dollars(min))")
            case let (nil, max?): parts.append("under \(dollars(max))")
            case (nil, nil): break
            }
        }
        if let days = filters.days {
            switch (days.start, days.end) {
            case let (start?, end?): parts.append(periodText(start, end, calendar: calendar) ?? "\(start.text)..\(end.text)")
            case let (start?, nil): parts.append("since \(start.text)")
            case let (nil, end?): parts.append("until \(end.text)")
            case (nil, nil): break
            }
        }
        if let card = filters.card { parts.append("card \(card)") }
        return parts.joined(separator: " ")
    }

    /// "2025", "q3 2026", "march 2026", or "2026-03-14" when the range is that period. Nil for other ranges.
    private static func periodText(_ start: Day, _ end: Day, calendar: Calendar) -> String? {
        if start == end { return start.text }
        guard start.year == end.year, start.day == 1 else { return nil }
        if yearRange(start.year, calendar: calendar) == DayRange(start: start, end: end) { return "\(start.year)" }
        if start.month % 3 == 1, quarterRange((start.month - 1) / 3 + 1, year: start.year, calendar: calendar) == DayRange(start: start, end: end) {
            return "q\((start.month - 1) / 3 + 1) \(start.year)"
        }
        if monthRange(start.month, year: start.year, calendar: calendar) == DayRange(start: start, end: end) {
            return "\(monthNames[start.month - 1]) \(start.year)"
        }
        return nil
    }
}

// MARK: - Sentence

public enum ReceiptField: Sendable, Hashable {
    case kinds, merchant, amount, days, card
}

public enum ReceiptSentencePart: Equatable, Sendable {
    case words(String)
    /// A value that opens the editor of its filter.
    case token(ReceiptField, String)
}

/// The filters as one sentence, for example
/// "Orders, subscriptions, and refunds from Amazon that mention "toner", for $40.00 to $60.00, in July 2026,
/// paid with Visa 6534."
public func receiptSentence(
    _ filters: ReceiptFilters, merchantName: String?, cardName: String?, calendar: Calendar = .current
) -> [ReceiptSentencePart] {
    var parts: [ReceiptSentencePart] = [.token(.kinds, kindsPhrase(filters.kinds))]

    parts.append(.words("from"))
    parts.append(.token(.merchant, filters.merchant == nil ? "any merchant" : merchantName ?? filters.merchant ?? ""))
    if !filters.words.isEmpty { parts.append(.words("that mention “\(filters.words)”")) }

    parts.append(.words(", for"))
    parts.append(.token(.amount, amountPhrase(filters.amount)))

    let (preposition, days) = daysPhrase(filters.days, calendar: calendar)
    parts.append(.words(", \(preposition)"))
    parts.append(.token(.days, days))

    parts.append(.words(", paid with"))
    parts.append(.token(.card, filters.card == nil ? "any card" : cardName ?? "card \(filters.card ?? "")"))
    parts.append(.words("."))
    return parts
}

/// One word of the sentence, for a layout that wraps words.
public struct ReceiptSentenceWord: Equatable, Sendable {
    public let text: String
    /// Nil for the plain words.
    public let field: ReceiptField?
    /// True when no space comes before the word, for example the comma after a token.
    public let attached: Bool

    public init(text: String, field: ReceiptField?, attached: Bool) {
        self.text = text
        self.field = field
        self.attached = attached
    }
}

public func receiptSentenceWords(_ parts: [ReceiptSentencePart]) -> [ReceiptSentenceWord] {
    var words: [ReceiptSentenceWord] = []
    var space = false
    for part in parts {
        switch part {
        case .words(let text):
            for (index, piece) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { space = true }
                guard !piece.isEmpty else { continue }
                words.append(ReceiptSentenceWord(text: String(piece), field: nil, attached: !space && !words.isEmpty))
                space = false
            }
        case .token(let field, let value):
            words.append(ReceiptSentenceWord(text: value, field: field, attached: !space && !words.isEmpty))
            space = false
        }
    }
    return words
}

private func kindsPhrase(_ kinds: Set<ReceiptKind>) -> String {
    let names = ReceiptKind.allCases.filter(kinds.contains).map(\.plural)
    let text: String
    switch names.count {
    case ReceiptKind.allCases.count: text = "all receipts"
    case 0: text = "no receipts"
    case 1: text = names[0]
    case 2: text = "\(names[0]) and \(names[1])"
    default: text = names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
    }
    return text.prefix(1).uppercased() + text.dropFirst()
}

private func amountPhrase(_ amount: AmountRange?) -> String {
    let money = { (minor: Int) in Money.format(minor, currency: "USD") }
    switch (amount?.min, amount?.max) {
    case let (min?, max?) where min == max: return money(min)
    case let (min?, max?): return "\(money(min)) to \(money(max))"
    case let (min?, nil): return "\(money(min)) or more"
    case let (nil, max?): return "\(money(max)) or less"
    case (nil, nil): return "any amount"
    }
}

/// The preposition and the token text, for example ("in", "July 2026").
private func daysPhrase(_ days: DayRange?, calendar: Calendar) -> (String, String) {
    switch (days?.start, days?.end) {
    case let (start?, end?) where start == end: return ("on", start.display)
    case let (start?, end?):
        if start.day == 1, ReceiptQuery.monthRange(start.month, year: start.year, calendar: calendar) == DayRange(start: start, end: end) {
            return ("in", "\(ReceiptQuery.monthNames[start.month - 1].capitalized) \(start.year)")
        }
        if ReceiptQuery.yearRange(start.year, calendar: calendar) == DayRange(start: start, end: end) { return ("in", "\(start.year)") }
        return ("from", "\(start.display) to \(end.display)")
    case let (start?, nil): return ("since", start.display)
    case let (nil, end?): return ("until", end.display)
    case (nil, nil): return ("at", "any time")
    }
}
