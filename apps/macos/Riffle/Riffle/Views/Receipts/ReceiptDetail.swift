// The detail column: the merchant and the amount, then two tabs. Receipt: the items, the totals, and the PDF from the
// merchant. Email: the email, a link to it in Gmail, the related receipts, and the PDF of the email.

import AppKit
import RiffleKit
import SwiftUI

struct ReceiptDetail: View {
    enum Tab: Hashable {
        case receipt, email
    }

    let model: ReceiptsModel
    let receipt: Receipt
    let pdfs: PDFCache

    @State private var tab: Tab = .receipt

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Show", selection: $tab) {
                Text("Receipt").tag(Tab.receipt)
                Text("Email").tag(Tab.email)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.bottom, 14)
            Divider()
            switch tab {
            case .receipt: receiptTab
            case .email: emailTab
            }
        }
    }

    // MARK: Header

    private var day: Day { model.day(of: receipt) }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(receipt.merchant ?? "Unknown merchant")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let total = receipt.signedTotal {
                    Text(Money.format(total, currency: receipt.currency))
                        .font(Theme.receiptAmountFont)
                }
            }
            HStack(spacing: 14) {
                Text("\(receipt.kind.singular) on \(day.display)")
                if let card = receipt.card {
                    Text("Paid with \(card.name)")
                } else if let method = receipt.paymentMethod {
                    Text("Paid with \(method)")
                }
                if let orderId = receipt.orderId {
                    Text("Order \(orderId)")
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.receiptColumnMargin)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Receipt tab

    private var receiptTab: some View {
        VSplitView {
            ScrollView {
                breakdown
                    .padding(Theme.receiptColumnMargin)
            }
            .frame(minHeight: 120, idealHeight: breakdownHeight, maxHeight: .infinity)
            if receipt.proof == .merchant {
                ProofPDFView(model: model, receipt: receipt, which: .best, cache: pdfs)
                    .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No PDF from the merchant",
                    systemImage: "doc",
                    description: Text(receipt.hasEmailPdf
                        ? "Riffle has only the email for this receipt. The Email tab shows it."
                        : "Riffle has no PDF for this receipt yet. The Email tab opens it in Gmail.")
                )
                .frame(minHeight: 200, maxHeight: .infinity)
            }
        }
    }

    /// Enough height for the items and the totals, so the split starts without a scroll.
    private var breakdownHeight: CGFloat {
        let rows = receipt.items.count + [receipt.subtotal, receipt.tax, receipt.shippingCost, receipt.discount, receipt.total].compactMap { $0 }.count
            + (receipt.plan == nil ? 0 : 1) + (receipt.periodStart == nil ? 0 : 1)
        return min(360, 2 * Theme.receiptColumnMargin + CGFloat(max(rows, 1)) * 26 + 12)
    }

    private var breakdown: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(Array(receipt.items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.description)
                            .lineLimit(2)
                        if let quantity = item.quantity, quantity != 1 {
                            Text(Self.quantityText(item, currency: receipt.currency))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    amountCell(item.total)
                }
            }
            if !receipt.items.isEmpty, hasTotals {
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
            }
            totalRow("Subtotal", receipt.subtotal)
            totalRow("Tax", receipt.tax)
            totalRow("Shipping", receipt.shippingCost)
            totalRow("Discount", receipt.discount.map { -$0 })
            totalRow("Total", receipt.total, emphasis: true)
            if let plan = receipt.plan {
                textRow("Plan", plan)
            }
            if let start = receipt.periodStart {
                textRow("Period", receipt.periodEnd.map { "\(Self.dayText(start)) to \(Self.dayText($0))" } ?? "From \(Self.dayText(start))")
            }
            if receipt.items.isEmpty, !hasTotals {
                GridRow {
                    Text("The email gives no items or totals.")
                        .foregroundStyle(.secondary)
                        .gridCellColumns(2)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var hasTotals: Bool {
        [receipt.subtotal, receipt.tax, receipt.shippingCost, receipt.discount, receipt.total].contains { $0 != nil }
    }

    @ViewBuilder
    private func totalRow(_ label: String, _ minor: Int?, emphasis: Bool = false) -> some View {
        if let minor {
            GridRow {
                Text(label)
                    .foregroundStyle(emphasis ? .primary : .secondary)
                    .fontWeight(emphasis ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                amountCell(minor, emphasis: emphasis)
            }
        }
    }

    private func textRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .gridColumnAlignment(.trailing)
        }
    }

    private func amountCell(_ minor: Int?, emphasis: Bool = false) -> some View {
        Text(minor.map { Money.format($0, currency: receipt.currency) } ?? "")
            .monospacedDigit()
            .fontWeight(emphasis ? .semibold : .regular)
            .gridColumnAlignment(.trailing)
    }

    /// For example "3 at $12.99".
    private static func quantityText(_ item: ReceiptItem, currency: String?) -> String {
        let count = item.quantity.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? ""
        guard let unitPrice = item.unitPrice else { return count }
        return "\(count) at \(Money.format(unitPrice, currency: currency))"
    }

    /// "2026-09-28" as "28 Sep 2026". Other text stays as the model wrote it.
    private static func dayText(_ text: String) -> String {
        Day(text)?.display ?? text
    }

    // MARK: Email tab

    private var emailTab: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.subject.isEmpty ? "(no subject)" : receipt.subject)
                            .font(.headline)
                            .textSelection(.enabled)
                        Text("Received \(receipt.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Button("Open in Gmail", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(receipt.gmailUrl) }
                        Button("Copy Link", systemImage: "link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(receipt.gmailUrl.absoluteString, forType: .string)
                        }
                    }
                    related
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.receiptColumnMargin)
            }
            .frame(minHeight: 120, idealHeight: 200, maxHeight: .infinity)
            if receipt.hasEmailPdf {
                ProofPDFView(model: model, receipt: receipt, which: .email, cache: pdfs)
                    .frame(minHeight: 200, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No PDF of the email yet",
                    systemImage: "envelope",
                    description: Text("Riffle makes the PDF after the receipt is found. Open the email in Gmail to read it now.")
                )
                .frame(minHeight: 200, maxHeight: .infinity)
            }
        }
    }

    /// The other receipts of the same email, and the receipts of the same order. A click selects one.
    @ViewBuilder private var related: some View {
        let others = model.related(to: receipt)
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(others.count == 1 ? "1 related receipt" : "\(others.count) related receipts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(others) { other in
                    Button {
                        model.selection = other.id
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(other.messageId == receipt.messageId ? "Same email" : other.kind.singular)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            Text(other.subject)
                                .lineLimit(1)
                            Spacer()
                            Text(model.day(of: other).display)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if let total = other.signedTotal {
                                Text(Money.format(total, currency: other.currency))
                                    .monospacedDigit()
                                    .frame(width: 90, alignment: .trailing)
                            }
                        }
                        .font(.callout)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
