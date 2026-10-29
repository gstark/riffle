// Rules that find a sign-in page in the Riffle browser. The server has stricter rules (classify() in
// src/receipts/proof.ts). These rules stop the runner before it prints and uploads a sign-in page.

import Foundation

public enum SignInCheck {
    private static let words = ["signin", "sign-in", "sign_in", "login", "log-in", "log_in", "signon"]

    /// True when the page has a password field, or its address looks like a sign-in page.
    public static func isSignInPage(url: URL?, hasPasswordField: Bool) -> Bool {
        if hasPasswordField { return true }
        guard let url, let host = url.host() else { return false }
        let address = (host + url.path()).lowercased()
        return words.contains { address.contains($0) }
    }
}
