// The receipt filters as one sentence, in the same serif as the search panel. Each value is a token with a menu, or
// a popover for the amount. A change writes the search text, so the text and the sentence always agree.

import RiffleKit
import SwiftUI

struct ReceiptSentenceView: View {
    let model: ReceiptsModel

    @State private var amountEditorShown = false

    var body: some View {
        let filters = model.filters
        let parts = receiptSentence(filters, merchantName: model.merchantName(filters.merchant), cardName: model.cardName(filters.card))
        WrapLayout(lineHeight: Theme.receiptSentenceLineHeight, spacing: 4) {
            ForEach(Array(receiptSentenceWords(parts).enumerated()), id: \.offset) { _, word in
                wordView(word)
                    .layoutValue(key: AttachedKey.self, value: word.attached)
            }
        }
        .font(Theme.receiptSentenceFont)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    @ViewBuilder
    private func wordView(_ word: ReceiptSentenceWord) -> some View {
        switch word.field {
        case nil:
            Text(word.text).foregroundStyle(Theme.secondary)
        case .kinds:
            tokenMenu(word.text) { kindItems }
        case .merchant:
            tokenMenu(word.text) { merchantItems }
        case .amount:
            Button {
                amountEditorShown.toggle()
            } label: {
                TokenLabel(text: word.text, selected: amountEditorShown)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $amountEditorShown, arrowEdge: .bottom) {
                AmountEditor(model: model, shown: $amountEditorShown)
            }
            .accessibilityHint("Edits the amount filter")
        case .days:
            tokenMenu(word.text) { dayItems }
        case .card:
            tokenMenu(word.text) { cardItems }
        }
    }

    private func tokenMenu<Items: View>(_ text: String, @ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            TokenLabel(text: text, selected: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityHint("Edits this filter")
    }

    // MARK: Menu items

    @ViewBuilder private var kindItems: some View {
        ForEach(ReceiptKind.allCases, id: \.self) { kind in
            Toggle(kind.pluralTitle, isOn: Binding(
                get: { model.filters.kinds.contains(kind) },
                set: { on in
                    var filters = model.filters
                    if on { filters.kinds.insert(kind) } else { filters.kinds.remove(kind) }
                    model.setFilters(filters)
                }
            ))
        }
    }

    @ViewBuilder private var merchantItems: some View {
        Button("Any merchant") { model.select(merchant: nil) }
        Divider()
        ForEach(model.merchantGroups) { group in
            Button("\(group.name) (\(group.count))") { model.select(merchant: group.id) }
        }
    }

    @ViewBuilder private var dayItems: some View {
        Button("Any time") { model.select(month: nil) }
        Divider()
        ForEach(["This month", "Last month", "Last 30 days", "This year", "Last year"], id: \.self) { preset in
            Button(preset) { setDays(ReceiptQuery.parse(preset.lowercased(), today: Day(.now)).days) }
        }
        Divider()
        ForEach(model.monthGroups) { group in
            Button("\(group.name) (\(group.count))") { model.select(month: group.id) }
        }
    }

    @ViewBuilder private var cardItems: some View {
        Button("Any card") { setCard(nil) }
        Divider()
        ForEach(model.cards) { card in
            Button("\(card.name) (\(card.count))") { setCard(card.id) }
        }
    }

    private func setDays(_ days: DayRange?) {
        var filters = model.filters
        filters.days = days
        model.setFilters(filters)
    }

    private func setCard(_ last4: String?) {
        var filters = model.filters
        filters.card = last4
        model.setFilters(filters)
    }
}

/// The lowest and the highest amount, in dollars. An empty end has no limit.
private struct AmountEditor: View {
    let model: ReceiptsModel
    @Binding var shown: Bool

    @State private var lowest = ""
    @State private var highest = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Amount")
                .font(Theme.receiptLabelFont)
            HStack(spacing: 8) {
                TextField("Lowest", text: $lowest)
                    .frame(width: 120)
                Text("to")
                    .foregroundStyle(.secondary)
                TextField("Highest", text: $highest)
                    .frame(width: 120)
                Button("Apply", action: apply)
                    .keyboardShortcut(.defaultAction)
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(apply)
            Text("In dollars. Leave an end empty for no limit. One amount in both fields finds that exact amount.")
                .font(Theme.receiptBodyFont)
                .foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading)
            HStack(spacing: 8) {
                presetButton("Under $20", AmountRange(min: nil, max: 2000))
                presetButton("$20 to $100", AmountRange(min: 2000, max: 10_000))
                presetButton("Over $100", AmountRange(min: 10_000, max: nil))
                presetButton("Any amount", nil)
            }
            .controlSize(.large)
        }
        .font(Theme.receiptBodyFont)
        .padding(16)
        .onAppear {
            lowest = model.filters.amount?.min.map { Money.plain($0, currency: "USD") } ?? ""
            highest = model.filters.amount?.max.map { Money.plain($0, currency: "USD") } ?? ""
        }
    }

    private func presetButton(_ title: String, _ range: AmountRange?) -> some View {
        Button(title) { set(range) }
    }

    private func apply() {
        switch (Self.cents(lowest), Self.cents(highest)) {
        case (nil, nil): set(nil)
        case let (low?, high?): set(AmountRange(min: min(low, high), max: max(low, high)))
        case let (low, high): set(AmountRange(min: low, max: high))
        }
    }

    private func set(_ range: AmountRange?) {
        var filters = model.filters
        filters.amount = range
        model.setFilters(filters)
        shown = false
    }

    /// "42.17", "$42", or "1,200" in cents. Nil for empty or unreadable text.
    private static func cents(_ text: String) -> Int? {
        let clean = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, let value = Decimal(string: clean, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return NSDecimalNumber(decimal: value * 100).intValue
    }
}
