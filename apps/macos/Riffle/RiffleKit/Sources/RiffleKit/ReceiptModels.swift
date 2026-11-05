// The receipts of the Receipts window. See BrowseReceipt in src/receipts/browse.ts.

import Foundation

public enum ReceiptKind: String, CaseIterable, Sendable, Decodable {
    case order, subscription, refund, shipping

    /// For example "orders".
    public var plural: String {
        switch self {
        case .order: "orders"
        case .subscription: "subscriptions"
        case .refund: "refunds"
        case .shipping: "shipping notices"
        }
    }
}

/// "merchant": a PDF from the merchant, for example an invoice. "email": only the PDF of the email.
public enum ProofKind: String, Sendable, Decodable {
    case merchant, email
}

public struct ReceiptItem: Equatable, Sendable, Decodable {
    public let description: String
    public let quantity: Double?
    /// Minor units
    public let unitPrice: Int?
    public let total: Int?

    public init(description: String, quantity: Double? = nil, unitPrice: Int? = nil, total: Int? = nil) {
        self.description = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.total = total
    }
}

public struct Receipt: Identifiable, Equatable, Sendable, Decodable {
    /// "<messageId>:<n>"
    public let id: String
    public let gmailUrl: URL
    /// Gmail receive time
    public let date: Date
    public let kind: ReceiptKind
    public let subject: String
    public let merchant: String?
    public let orderId: String?
    /// "YYYY-MM-DD" from the model. It can be wrong, so `day` checks it.
    public let purchaseDate: String?
    public let currency: String?
    /// Minor units of `currency`, always positive. A refund has kind `.refund`.
    public let total: Int?
    public let subtotal: Int?
    public let tax: Int?
    public let shippingCost: Int?
    public let discount: Int?
    public let paymentMethod: String?
    public let items: [ReceiptItem]
    public let plan: String?
    public let periodStart: String?
    public let periodEnd: String?
    /// The best PDF of the receipt. Nil when it has none.
    public let proof: ProofKind?
    /// True when the archive has a PDF of the email.
    public let hasEmailPdf: Bool

    public init(
        id: String, gmailUrl: URL = URL(string: "https://mail.google.com/")!, date: Date, kind: ReceiptKind = .order,
        subject: String = "", merchant: String? = nil, orderId: String? = nil, purchaseDate: String? = nil,
        currency: String? = "USD", total: Int? = nil, subtotal: Int? = nil, tax: Int? = nil, shippingCost: Int? = nil,
        discount: Int? = nil, paymentMethod: String? = nil, items: [ReceiptItem] = [], plan: String? = nil,
        periodStart: String? = nil, periodEnd: String? = nil, proof: ProofKind? = nil, hasEmailPdf: Bool = false
    ) {
        self.id = id
        self.gmailUrl = gmailUrl
        self.date = date
        self.kind = kind
        self.subject = subject
        self.merchant = merchant
        self.orderId = orderId
        self.purchaseDate = purchaseDate
        self.currency = currency
        self.total = total
        self.subtotal = subtotal
        self.tax = tax
        self.shippingCost = shippingCost
        self.discount = discount
        self.paymentMethod = paymentMethod
        self.items = items
        self.plan = plan
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.proof = proof
        self.hasEmailPdf = hasEmailPdf
    }

    /// The Gmail message ID, the part of `id` before the colon. The receipts of one email share it.
    public var messageId: String {
        guard let colon = id.lastIndex(of: ":") else { return id }
        return String(id[..<colon])
    }

    /// The purchase date, or the day of the email when the purchase date is missing or not valid.
    public func day(calendar: Calendar = .current) -> Day {
        purchaseDate.flatMap(Day.init) ?? Day(date, calendar: calendar)
    }

    /// The total with a sign: a refund is negative.
    public var signedTotal: Int? {
        total.map { kind == .refund ? -$0 : $0 }
    }

    /// The tax with a sign: the tax of a refund is negative.
    public var signedTax: Int? {
        tax.map { kind == .refund ? -$0 : $0 }
    }

    /// The card, for example "Visa 6534". Nil without a payment method.
    public var card: Card? { Card(paymentMethod) }

    /// The key of `merchant` that groups names such as "Amazon" and "Amazon.com".
    public var merchantKey: String? { merchant.map(Merchant.key) }
}

public enum Merchant {
    /// Lower case, without ".com" and without punctuation at the ends.
    public static func key(_ name: String) -> String {
        var key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".com", ", inc.", ", inc", " inc.", " inc", " llc"] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
        }
        return key.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }
}

/// A payment method. The model writes one card in many ways, for example "Visa ending 6534" and
/// "Credit card ending in 6534", so the last four digits identify a card.
public struct Card: Hashable, Sendable {
    /// For example "Visa" or "Apple Pay". Nil when the payment method names no known brand.
    public let brand: String?
    public let last4: String?

    private static let brands: [(pattern: String, name: String)] = [
        ("american express", "Amex"), ("amex", "Amex"), ("visa", "Visa"), ("mastercard", "Mastercard"),
        ("master card", "Mastercard"), ("discover", "Discover"), ("apple pay", "Apple Pay"), ("paypal", "PayPal"),
    ]

    public init(brand: String?, last4: String?) {
        self.brand = brand
        self.last4 = last4
    }

    public init?(_ method: String?) {
        guard let method, !method.isEmpty else { return nil }
        let lower = method.lowercased()
        brand = Self.brands.first { lower.contains($0.pattern) }?.name
        last4 = Self.lastFourDigits(method)
        if brand == nil, last4 == nil { return nil }
    }

    /// The last group of exactly four digits, for example "0402" in "XXXXXX0402".
    static func lastFourDigits(_ text: String) -> String? {
        var groups: [String] = []
        var current = ""
        for character in text + " " {
            if character.isASCII, character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { groups.append(current) }
                current = ""
            }
        }
        // "XXXXXX0402" gives "0402". A longer group is not a card number end, for example a year.
        return groups.last { $0.count == 4 }
    }

    /// For example "Visa 6534", "Card 6534", or "Apple Pay".
    public var name: String {
        switch (brand, last4) {
        case let (brand?, last4?): "\(brand) \(last4)"
        case let (nil, last4?): "Card \(last4)"
        case let (brand?, nil): brand
        case (nil, nil): "Card"
        }
    }
}

public enum Money {
    /// The digits after the decimal point, as currencyDigits() in src/receipts/row.ts.
    public static func digits(_ currency: String?) -> Int {
        formatter(currency).maximumFractionDigits
    }

    /// For example "$23.45". A negative amount is in parentheses, as in accounting: "($23.45)".
    public static func format(_ minor: Int, currency: String?) -> String {
        let formatter = formatter(currency)
        let value = Decimal(abs(minor)) / pow(10, formatter.maximumFractionDigits)
        let text = formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
        return minor < 0 ? "(\(text))" : text
    }

    /// The plain number for a CSV file, for example "-23.45".
    public static func plain(_ minor: Int, currency: String?) -> String {
        let digits = digits(currency)
        let value = Decimal(minor) / pow(10, digits)
        return (value as NSDecimalNumber).description(withLocale: Locale(identifier: "en_US_POSIX"))
    }

    private static func formatter(_ currency: String?) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency ?? "USD"
        return formatter
    }
}
