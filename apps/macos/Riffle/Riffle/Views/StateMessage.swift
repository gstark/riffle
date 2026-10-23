// One line above the results that says what is happening or what went wrong.
// A search with no results shows the large NoMatchesView.

import RiffleKit
import SwiftUI

struct StateMessage: View {
    let model: SearchModel

    var body: some View {
        if model.phase == .done && model.results.isEmpty {
            NoMatchesView()
        } else if let message {
            Text(message)
                .font(Theme.detailFont)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.margin)
                .padding(.vertical, 16)
        }
    }

    private var message: String? {
        switch model.phase {
        case .idle, .reading, .filtering:
            nil
        case .failed(let error):
            Self.text(for: error)
        case .done:
            if model.source == .plain {
                "Claude could not read this search. Riffle searched for your words as typed."
            } else {
                nil
            }
        }
    }

    private static func text(for error: SearchError) -> String {
        switch error {
        case .unauthorized: "Riffle's token is not accepted. Open Settings to replace it."
        case .network: "Riffle cannot reach the search service. Check your connection, then press Return."
        case .server, .timeout: "The search failed. Press Return to try again."
        case .badRequest(let message): message
        }
    }
}
