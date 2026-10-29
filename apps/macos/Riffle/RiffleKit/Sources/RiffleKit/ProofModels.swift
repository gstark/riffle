// The request and response shapes of the /proofs routes. See src/receipts/signed-in.ts.

import Foundation

/// A receipt whose link needs a sign-in, or blocks the browser in AWS.
public struct PendingReceipt: Decodable, Identifiable, Hashable, Sendable {
    /// "<messageId>:<n>"
    public let id: String
    public let messageId: String
    public let date: Date
    public let subject: String
    public let merchant: String?
    public let orderId: String?
    /// Minor units of `currency`
    public let total: Int?
    public let currency: String?
    /// The receipt link of the email, where you sign in. Nil for some Amazon orders.
    public let url: URL?
    /// The page that Riffle prints
    public let printUrl: URL

    public init(
        id: String, messageId: String, date: Date, subject: String, merchant: String?, orderId: String?,
        total: Int?, currency: String?, url: URL?, printUrl: URL
    ) {
        self.id = id
        self.messageId = messageId
        self.date = date
        self.subject = subject
        self.merchant = merchant
        self.orderId = orderId
        self.total = total
        self.currency = currency
        self.url = url
        self.printUrl = printUrl
    }

    /// The page to open for a sign-in.
    public var signInUrl: URL { url ?? printUrl }

    /// For example "$23.45". Nil without a total.
    public var amount: String? {
        guard let total else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency ?? "USD"
        // The minor units of the currency, as currencyDigits() in src/receipts/row.ts.
        let value = Decimal(total) / pow(10, formatter.maximumFractionDigits)
        return formatter.string(from: value as NSDecimalNumber)
    }
}

/// The pending receipts of one site, for example "amazon.com".
public struct PendingSite: Decodable, Identifiable, Hashable, Sendable {
    public let site: String
    /// The most frequent merchant name of the receipts
    public let merchant: String
    public let receipts: [PendingReceipt]

    public var id: String { site }

    public init(site: String, merchant: String, receipts: [PendingReceipt]) {
        self.site = site
        self.merchant = merchant
        self.receipts = receipts
    }
}

/// Where to PUT the PDF of a receipt.
public struct UploadTicket: Decodable, Equatable, Sendable {
    public let url: URL
    public let key: String

    public init(url: URL, key: String) {
        self.url = url
        self.key = key
    }
}

/// What Riffle saw on the printed page. The server classifies it.
public struct PageResult: Encodable, Equatable, Sendable {
    public let id: String
    public let finalUrl: String
    public let status: Int?
    public let hasPasswordField: Bool
    public let text: String

    public init(id: String, finalUrl: String, status: Int?, hasPasswordField: Bool, text: String) {
        self.id = id
        self.finalUrl = finalUrl
        self.status = status
        self.hasPasswordField = hasPasswordField
        self.text = text
    }

    // `status` is null in the JSON when it is nil. The API needs the key.
    private enum CodingKeys: String, CodingKey {
        case id, finalUrl, status, hasPasswordField, text
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(finalUrl, forKey: .finalUrl)
        try container.encode(status, forKey: .status)
        try container.encode(hasPasswordField, forKey: .hasPasswordField)
        try container.encode(text, forKey: .text)
    }
}

/// The fidelity that the server gave a page. See FIDELITIES in src/receipts/proof.ts.
public struct ProofFidelity: Decodable, Equatable, Sendable {
    public let fidelity: String

    public init(_ fidelity: String) {
        self.fidelity = fidelity
    }

    /// The server did not keep the page because it is a sign-in page or a robot check.
    public var needsSignIn: Bool { fidelity == "login_required" || fidelity == "blocked" }
    /// The server kept the page.
    public var isKept: Bool { fidelity == "merchant_page" || fidelity == "unverified_page" }
}
