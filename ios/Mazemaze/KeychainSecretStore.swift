import Foundation
import Security
import MazemazeCore

/// The access token lives only in the iOS Keychain (this device, while unlocked). It is never
/// written to UserDefaults, never logged, and never handed to web page scripts.
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let service = "mazemaze.api"
    private let account = "token"

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func token() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setToken(_ token: String?) throws {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
