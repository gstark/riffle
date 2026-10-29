// Looks for the total or the order ID of a receipt in the text of a page, so Riffle prints only a page that shows the
// receipt. The server has the same rules (amountTexts and showsReceipt in src/receipts/proof.ts) and checks again.

import Foundation

public enum ReceiptScan {
    /// Symbols for a whole amount without cents, for example "$65".
    private static let symbols = ["USD": "$", "CAD": "$", "AUD": "$", "EUR": "€", "GBP": "£"]

    /// True when the text shows the total or the order ID of the receipt. An amount must not be part of a larger
    /// number: "13.90" is not in "113.90" or "13.905". Each run of white space counts as one space.
    public static func shows(_ receipt: PendingReceipt, in text: String) -> Bool {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let range = NSRange(flat.startIndex..., in: flat)
        let amounts = receipt.total.map { amountTexts(minor: $0, currency: receipt.currency) } ?? []
        let foundAmount = amounts.contains { amount in
            let pattern = #"(?<![\d.,])"# + amountPattern(amount) + #"(?!\d| ?[.,] ?\d)"#
            return (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: flat, range: range) != nil
        }
        let orderIds = (receipt.orderId ?? "").components(separatedBy: ",")
            .map { String($0.drop(while: \.isWhitespace)) }
            .filter { $0.count >= 4 }
        return foundAmount || orderIds.contains { flat.contains($0) }
    }

    /// A pattern for an amount that also finds it with a space between its parts. A page can put the parts in
    /// different elements: `<div>$44</div><span>.12</span>` has the text "$44\n.12".
    private static func amountPattern(_ amount: String) -> String {
        let parts = try! NSRegularExpression(pattern: #"\d+|[^\d\s]"#)
        let range = NSRange(amount.startIndex..., in: amount)
        return parts.matches(in: amount, range: range)
            .compactMap { Range($0.range, in: amount).map { NSRegularExpression.escapedPattern(for: String(amount[$0])) } }
            .joined(separator: " ?")
    }

    /// The ways a page can write the amount: "1234.56", "1,234.56", "1234,56", "1.234,56", "1 234,56", and "$1,234"
    /// for an amount without cents.
    static func amountTexts(minor: Int, currency: String?) -> [String] {
        let digits = currencyDigits(currency)
        let scale = Int(pow(10, Double(digits)))
        let whole = String(abs(minor) / scale)
        let cents = String(abs(minor) % scale)
        let fraction: String? = digits == 0 ? nil : String(repeating: "0", count: digits - cents.count) + cents
        func join(_ text: String, _ point: String) -> String { fraction.map { text + point + $0 } ?? text }

        var texts = [
            join(whole, "."),
            join(group(whole, ","), "."),
            join(whole, ","),
            join(group(whole, "."), ","),
            join(group(whole, " "), ","),
        ]
        if let symbol = symbols[currency ?? ""], let fraction, fraction.allSatisfy({ $0 == "0" }) {
            texts.append(symbol + group(whole, ","))
        }
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    /// Digits after the decimal point, as currencyDigits() in src/receipts/row.ts: 2 for USD, 0 for JPY.
    static func currencyDigits(_ currency: String?) -> Int {
        guard let currency else { return 2 }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.maximumFractionDigits
    }

    /// Puts `separator` between groups of three digits.
    private static func group(_ whole: String, _ separator: String) -> String {
        var result = ""
        for (index, digit) in whole.enumerated() {
            if index > 0, (whole.count - index) % 3 == 0 { result += separator }
            result.append(digit)
        }
        return result
    }
}
