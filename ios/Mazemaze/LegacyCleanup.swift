import Foundation
import Security

/// One-time cleanup for what the earlier version (which talked to a Mac server) left behind. The access token was stored in the
/// Keychain, and Keychain items survive deleting the app, so this version removes it once and never reads it. Nothing uses it any more.
enum LegacyCleanup {
    private static let doneKey = "mazemaze.legacyTokenRemoved"

    static func run(defaults: UserDefaults) {
        guard !defaults.bool(forKey: doneKey) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "mazemaze.api", kSecAttrAccount as String: "token"]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { defaults.set(true, forKey: doneKey) }
        // Old server settings (address, certificate fingerprint) are not read either; drop them.
        for key in ["mazemaze.serverURL", "mazemaze.fallbackURL", "mazemaze.tailscaleURL", "mazemaze.pin", "mazemaze.serverName",
                    "mazemaze.engine.meaning", "mazemaze.engine.fallbackToDevice", "mazemaze.engine.deviceTranslation"] {
            defaults.removeObject(forKey: key)
        }
    }
}
