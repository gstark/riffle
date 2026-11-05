// The sidebar: the merchants or the months, with the number of receipts and the net amount of each.
// A click filters the ledger. The counts follow the other filters, so you can see where an amount was spent.

import RiffleKit
import SwiftUI

struct ReceiptsSidebar: View {
    enum Mode: Hashable {
        case merchants, months
    }

    let model: ReceiptsModel
    @Binding var mode: Mode

    /// The tag of the first row, which removes the filter.
    private static let all = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Group by", selection: $mode) {
                Text("Merchants").tag(Mode.merchants)
                Text("Months").tag(Mode.months)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(Theme.receiptBodyFont)
            .controlSize(.large)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(selection: selection) {
                HStack {
                    Text(mode == .merchants ? "All merchants" : "All months")
                    Spacer()
                    Text("\(groups.reduce(0) { $0 + $1.count })")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(Theme.receiptBodyFont)
                .tag(Self.all)
                ForEach(groups) { group in
                    GroupRow(group: group).tag(group.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var groups: [ReceiptsModel.Group] {
        mode == .merchants ? model.merchantGroups : model.monthGroups
    }

    private var selection: Binding<String?> {
        Binding(
            get: {
                switch mode {
                case .merchants: model.filters.merchant ?? Self.all
                case .months: model.selectedMonth ?? Self.all
                }
            },
            set: { id in
                // A click on the empty space below the rows gives nil. The filter stays.
                guard let id else { return }
                let value = id == Self.all ? nil : id
                switch mode {
                case .merchants: model.select(merchant: value)
                case .months: model.select(month: value)
                }
            }
        )
    }
}

private struct GroupRow: View {
    let group: ReceiptsModel.Group

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(group.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(group.net.map(\.text).joined(separator: " "))
                    .monospacedDigit()
                Text(group.count == 1 ? "1 receipt" : "\(group.count) receipts")
                    .font(Theme.receiptBodyFont)
                    .foregroundStyle(.secondary)
            }
        }
        .font(Theme.receiptBodyFont)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}
