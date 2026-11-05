// The middle column: the search field, the filter sentence, one line of totals, and the ledger of receipts by month.

import AppKit
import RiffleKit
import SwiftUI

struct ReceiptLedger: View {
    @Bindable var model: ReceiptsModel

    @State private var text = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            ReceiptSentenceView(model: model)
                .padding(.horizontal, Theme.receiptColumnMargin)
                .padding(.bottom, 10)
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, Theme.receiptColumnMargin)
                .padding(.bottom, 12)
            Divider()
            content
        }
        // Riffle reads the text as you type. A token edit writes the text of the new filters.
        .onChange(of: text) { _, new in
            if new != model.query { model.setQuery(new) }
        }
        .onChange(of: model.query, initial: true) { _, new in
            if new != text { text = new }
        }
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.receiptSearchIconSize, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .accessibilityHidden(true)
            TextField("Merchant, amount, month, or words", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.receiptSearchFont)
                .focused($searchFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: Theme.receiptSearchIconSize))
                        .foregroundStyle(Theme.tertiary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear (Esc)")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Theme.receiptColumnMargin)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    /// For example "12 receipts, 1 refund. Net $412.17. Tax $31.20."
    private var summary: String {
        let totals = model.summary
        var count = totals.count == 1 ? "1 receipt" : "\(totals.count) receipts"
        if totals.refunds > 0 { count += ", " + (totals.refunds == 1 ? "1 refund" : "\(totals.refunds) refunds") }
        var parts = [count]
        if !totals.net.isEmpty { parts.append("Net " + totals.net.map(\.text).joined(separator: " and ")) }
        if totals.tax.contains(where: { $0.minor != 0 }) { parts.append("Tax " + totals.tax.map(\.text).joined(separator: " and ")) }
        return parts.joined(separator: ". ") + "."
    }

    @ViewBuilder private var content: some View {
        if model.receipts.isEmpty, model.load == .loading {
            ProgressView("Getting your receipts")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.receipts.isEmpty, model.load == .notLoaded {
            ContentUnavailableView(
                "Riffle is not connected",
                systemImage: "link",
                description: Text("Right-click the menu bar icon and choose Settings to enter the search URL and the token.")
            )
        } else if case .failed(let error) = model.load, model.receipts.isEmpty {
            ContentUnavailableView(
                "Riffle cannot get the receipts",
                systemImage: "exclamationmark.triangle",
                description: Text(Self.text(for: error))
            )
        } else if model.results.isEmpty, model.load == .loaded {
            noMatches
        } else {
            list
        }
    }

    private var noMatches: some View {
        ContentUnavailableView {
            Label("No receipts match", systemImage: "receipt")
        } description: {
            Text("Remove a filter or change the words.")
        } actions: {
            if model.canWidenAmount, let exact = model.filters.amount?.min {
                Button("Show amounts within \(Money.format(ReceiptFilters.nearTolerance, currency: "USD")) of \(Money.format(exact, currency: "USD"))") {
                    model.widenAmount()
                }
            }
        }
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.months) { month in
                Section {
                    ForEach(month.receipts) { receipt in
                        ReceiptLedgerRow(receipt: receipt, day: model.day(of: receipt))
                            .contextMenu { rowMenu(receipt) }
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(month.title)
                        Spacer()
                        Text(month.net.map(\.text).joined(separator: " "))
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func rowMenu(_ receipt: Receipt) -> some View {
        Button("Open Email in Gmail") { NSWorkspace.shared.open(receipt.gmailUrl) }
        if let total = receipt.total {
            Button("Copy Amount") { copy(Money.plain(total, currency: receipt.currency)) }
        }
        if let orderId = receipt.orderId {
            Button("Copy Order ID") { copy(orderId) }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func text(for error: SearchError) -> String {
        switch error {
        case .unauthorized: "Riffle's token is not accepted. Open Settings to replace it."
        case .network: "Riffle cannot reach the search service. Check your connection, then click Refresh."
        case .server, .timeout: "The search service failed. Click Refresh to try again."
        case .badRequest(let message): message
        }
    }
}

/// One line of the ledger: the day, the merchant and the subject, and the amount. A refund is in parentheses.
struct ReceiptLedgerRow: View {
    let receipt: Receipt
    let day: Day

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(dayText)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(receipt.merchant ?? "Unknown merchant")
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if receipt.kind != .order {
                        Text(receipt.kind.singular.lowercased())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(receipt.subject.isEmpty ? "(no subject)" : receipt.subject)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let total = receipt.signedTotal {
                Text(Money.format(total, currency: receipt.currency))
                    .monospacedDigit()
                    .fontWeight(receipt.kind == .refund ? .regular : .medium)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    /// For example "28 Sep", as the dates in the search panel.
    private var dayText: String {
        "\(day.day) \(Calendar.current.shortMonthSymbols[day.month - 1])"
    }
}

extension ReceiptKind {
    /// For example "Order".
    var singular: String {
        switch self {
        case .order: "Order"
        case .subscription: "Subscription"
        case .refund: "Refund"
        case .shipping: "Shipping notice"
        }
    }

    /// For example "Orders".
    var pluralTitle: String {
        plural.prefix(1).uppercased() + plural.dropFirst()
    }
}
