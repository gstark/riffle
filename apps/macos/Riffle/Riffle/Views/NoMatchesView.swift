// The large, centered state for a search with no results: an empty envelope that a magnifying glass searches.

import SwiftUI

struct NoMatchesView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeps = 0

    var body: some View {
        VStack(spacing: 18) {
            icon
            VStack(spacing: 8) {
                Text("No mail matches.")
                    .font(Theme.emptyTitleFont)
                    .foregroundStyle(Theme.text)
                Text("Remove a filter or change the words.")
                    .font(Theme.detailFont)
                    .foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .accessibilityElement(children: .combine)
        .onAppear { if !reduceMotion { sweeps += 1 } }
    }

    private var icon: some View {
        ZStack {
            Circle()
                .fill(Theme.selectedToken)
                .frame(width: Theme.emptyIconSize * 1.9, height: Theme.emptyIconSize * 1.9)
            Image(systemName: "envelope.open")
                .font(.system(size: Theme.emptyIconSize, weight: .light))
                .foregroundStyle(Theme.ink)
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.emptyIconSize * 0.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(9)
                .background(Theme.panel, in: Circle())
                // Move from side to side one time, as if the glass looks for mail in the envelope.
                .phaseAnimator([0, -1, 1, -0.6, 0], trigger: sweeps) { glass, side in
                    glass
                        .offset(x: side * Theme.emptyIconSize * 0.3, y: abs(side) * -6)
                        .rotationEffect(.degrees(side * -12))
                } animation: { _ in
                    .spring(duration: 0.38, bounce: 0.35)
                }
                .offset(x: Theme.emptyIconSize * 0.5, y: Theme.emptyIconSize * 0.42)
        }
        .accessibilityHidden(true)
    }
}
