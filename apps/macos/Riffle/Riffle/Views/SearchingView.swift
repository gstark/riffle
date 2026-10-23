// The centered state while a search runs: a magnifying glass that loops over a stack of envelopes.
// It uses the same circle, envelope, and glass as NoMatchesView.

import SwiftUI

struct SearchingView: View {
    /// Seconds for one loop of the glass.
    private static let period: TimeInterval = 1.6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            icon(at: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement()
        .accessibilityLabel("Searching")
    }

    /// The glass moves on a figure eight over the envelopes.
    private func icon(at time: TimeInterval) -> some View {
        let angle = time.truncatingRemainder(dividingBy: Self.period) / Self.period * 2 * .pi
        let size = Theme.emptyIconSize
        return ZStack {
            Circle()
                .fill(Theme.selectedToken)
                .frame(width: size * 1.9, height: size * 1.9)
            envelope
                .opacity(0.45)
                .scaleEffect(0.85)
                .offset(x: -size * 0.18, y: -size * 0.2)
            envelope
                .offset(x: size * 0.06, y: size * 0.06)
            Image(systemName: "magnifyingglass")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(9)
                .background(Theme.panel, in: Circle())
                .offset(x: sin(angle) * size * 0.55, y: size * 0.12 + sin(2 * angle) * size * 0.22)
        }
    }

    /// A paper envelope: the panel color inside an ink outline, so the envelope behind it does not show through.
    private var envelope: some View {
        ZStack {
            Image(systemName: "envelope.fill")
                .foregroundStyle(Theme.panel)
            Image(systemName: "envelope")
                .foregroundStyle(Theme.ink)
        }
        .font(.system(size: Theme.emptyIconSize, weight: .light))
    }
}
