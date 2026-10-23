// The result rows. The list scrolls when it is taller than Theme.resultsMaxHeight.

import RiffleKit
import SwiftUI

struct ResultList: View {
    let results: [SearchResult]
    let selection: SearchResult.ID?
    let open: (SearchResult) -> Void

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(results) { result in
                        ResultRow(result: result, selected: result.id == selection)
                            .id(result.id)
                            .onTapGesture { open(result) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, Theme.resultsMaxHeight))
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: results) {
                if let first = results.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 15))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 18)
                .opacity(result.hasAttachment ? 1 : 0)
                .accessibilityLabel("Has attachments")
                .accessibilityHidden(!result.hasAttachment)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(result.subject.isEmpty ? "(no subject)" : result.subject)
                        .font(Theme.subjectFont)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(Day(result.date).display)
                        .font(Theme.detailFont.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(result.senderName)
                        .font(Theme.detailFont)
                        .foregroundStyle(Theme.secondary)
                    let labels = LabelNames.rowLabels(result.labels)
                    if !labels.isEmpty {
                        Text(labels.joined(separator: ", "))
                            .font(Theme.smallFont)
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .lineLimit(1)
                Text(result.snippet)
                    .font(Theme.detailFont)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(selected ? 2 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(selected ? Theme.selectedRow : .clear, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
