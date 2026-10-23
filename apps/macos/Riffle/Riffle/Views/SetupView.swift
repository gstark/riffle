// The setup screen: the search URL and the token. Shows on the first start and from Settings….

import RiffleKit
import SwiftUI

struct SetupView: View {
    let model: SearchModel

    private enum Field: Hashable {
        case url, token
    }

    @State private var url = ""
    @State private var token = ""
    @State private var error: SearchModel.SetupError?
    @State private var testing = false
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connect Riffle to your search service")
                    .font(Theme.titleFont)
                Text("Riffle keeps the token in your Keychain.")
                    .font(Theme.detailFont)
                    .foregroundStyle(Theme.secondary)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    Text("Search URL").gridColumnAlignment(.trailing)
                    TextField("https://…lambda-url.us-east-2.on.aws/", text: $url)
                        .focused($focus, equals: .url)
                }
                GridRow {
                    Text("Token")
                    SecureField(model.isConnected ? "Leave empty to keep the saved token" : "Token", text: $token)
                        .focused($focus, equals: .token)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(Theme.detailFont)
            .onSubmit(save)

            HStack(spacing: 12) {
                if let error {
                    Text(error.message)
                        .font(Theme.detailFont)
                        .foregroundStyle(Color(nsColor: .systemRed))
                } else if testing {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if model.isConnected {
                    Button("Cancel") { model.showingSetup = false }
                }
                Button("Test and save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(testing)
            }
        }
        .padding(32)
        .controlSize(.large)
        .onAppear {
            url = model.savedURL?.absoluteString ?? ""
            focus = url.isEmpty ? .url : .token
        }
    }

    private func save() {
        guard !testing else { return }
        error = nil
        testing = true
        Task {
            defer { testing = false }
            do throws(SearchModel.SetupError) {
                try await model.testAndSave(url: url, token: token)
                token = ""
            } catch {
                self.error = error
            }
        }
    }
}
