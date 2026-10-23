// Where Riffle keeps the search URL (UserDefaults) and the token (Keychain).

import Foundation
import Security

public struct Connection: Equatable, Sendable {
    public let url: URL
    public let token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }
}

@MainActor
public protocol ConnectionStore {
    /// The saved URL, also when no token is saved.
    var url: URL? { get }
    /// The saved URL and token, or nil if either is missing.
    func load() -> Connection?
    func save(_ connection: Connection) throws
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
}

public struct KeychainConnectionStore: ConnectionStore {
    private static let urlKey = "searchURL"
    private static let service = "com.gstark.riffle"
    private static let account = "search-token"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var url: URL? {
        defaults.string(forKey: Self.urlKey).flatMap(URL.init(string:))
    }

    public func load() -> Connection? {
        guard let url, let token = readToken() else { return nil }
        return Connection(url: url, token: token)
    }

    public func save(_ connection: Connection) throws {
        try writeToken(connection.token)
        defaults.set(connection.url.absoluteString, forKey: Self.urlKey)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    private func readToken() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToken(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
}
