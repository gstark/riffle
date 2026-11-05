// The detail column: a compact receipt header above the receipt PDF or its related email.

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
                if !receipt.items.isEmpty {
                    Text(receipt.items.map(\.description).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(receipt.items.map(\.description).joined(separator: ", "))
                }
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

    @ViewBuilder private var receiptTab: some View {
        if receipt.proof == .merchant {
            ProofPDFView(model: model, receipt: receipt, which: .best, cache: pdfs)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No PDF from the merchant",
                systemImage: "doc",
                description: Text(receipt.hasEmailPdf
                    ? "Riffle has only the email for this receipt. The Email tab shows it."
                    : "Riffle has no PDF for this receipt yet. The Email tab opens it in Gmail.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Email tab

    private var emailTab: some View {
        VStack(spacing: 0) {
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
            .frame(maxHeight: 200)
            Divider()
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
