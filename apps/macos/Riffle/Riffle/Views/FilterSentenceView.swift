// The filters as one sentence. Each value is a token that opens the editor of its filter.

import RiffleKit
import SwiftUI

struct FilterSentenceView: View {
    let model: SearchModel
    let filters: SearchFilters

    var body: some View {
        WrapLayout(lineHeight: Theme.sentenceLineHeight, spacing: 4) {
            ForEach(Array(sentenceWords(filterSentence(filters)).enumerated()), id: \.offset) { _, word in
                wordView(word)
                    .layoutValue(key: AttachedKey.self, value: word.attached)
            }
            if !filters.unsetFields.isEmpty {
                Button("+ filter") { toggle(.add) }
                    .buttonStyle(.plain)
                    .font(Theme.smallFont)
                    .foregroundStyle(model.editor == .add ? Theme.ink : Theme.tertiary)
                    .padding(.leading, 8)
            }
        }
        .font(Theme.sentenceFont)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    @ViewBuilder
    private func wordView(_ word: SentenceWord) -> some View {
        if let field = word.field {
            TokenButton(text: word.text, selected: model.editor == .field(field)) { toggle(.field(field)) }
        } else {
            Text(word.text).foregroundStyle(Theme.secondary)
        }
    }

    private func toggle(_ editor: SearchModel.Editor) {
        model.editor = model.editor == editor ? nil : editor
    }
}

private struct TokenButton: View {
    let text: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                // Dotted, 1.5 points thick, about 5 points below the baseline.
                .overlay(alignment: .bottom) {
                    HorizontalLine()
                        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.01, 3.5]))
                        .frame(height: 1.5)
                        .offset(y: 1)
                }
                .padding(.horizontal, 2)
                .background(selected ? Theme.selectedToken : .clear, in: RoundedRectangle(cornerRadius: Theme.tokenRadius))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edits this filter")
    }
}

private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// True when no space comes before the view, for example a comma after a token.
struct AttachedKey: LayoutValueKey {
    static let defaultValue = false
}

/// Places views left to right and wraps them onto lines of a fixed height.
struct WrapLayout: Layout {
    var lineHeight: CGFloat
    var spacing: CGFloat

    private struct Placement {
        let index: Int
        let x: CGFloat
        let line: Int
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let placements = arrange(width: width, subviews: subviews)
        let lines = (placements.last?.line ?? -1) + 1
        let usedWidth = placements.map { $0.x + $0.size.width }.max() ?? 0
        return CGSize(width: width.isFinite ? width : usedWidth, height: CGFloat(lines) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for placement in arrange(width: bounds.width, subviews: subviews) {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + (CGFloat(placement.line) + 0.5) * lineHeight),
                anchor: .leading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Placement] {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var line = 0
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let gap = index == 0 || subview[AttachedKey.self] ? 0 : spacing
            if x > 0, x + gap + size.width > width {
                line += 1
                x = 0
            } else {
                x += gap
            }
            placements.append(Placement(index: index, x: x, line: line, size: size))
            x += size.width
        }
        return placements
    }
}
