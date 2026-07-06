import Foundation
import Security

// MARK: - Keychain
//
// A tiny generic-password wrapper for the app's secrets — the OpenRouter API key
// and the Garmin login (OAuth tokens + email). Kept out of UserDefaults (which
// stores plaintext and, once the SwiftData store syncs, would be the wrong place
// for a secret) and marked synchronizable, so they follow the athlete across
// devices via iCloud Keychain rather than the CloudKit data store.

// Keychain access is thread-safe (Security framework), so this opts out of the
// module's default main-actor isolation — `GarminAuth` reads/writes tokens off the
// main actor.
nonisolated enum KeychainStore {
    /// Service namespace for every TriGenius keychain item.
    private static let service = "net.Narica.TriGenius"

    /// Account key for the OpenRouter API key.
    static let openRouterAPIKey = "openrouter_api_key"
    /// Account key for the Garmin DI OAuth tokens (JSON blob).
    static let garminTokens = "garmin_tokens"
    /// Account key for the Garmin login email (part of the credential set, so it
    /// syncs with the tokens and the account shows as logged-in on every device).
    static let garminEmail = "garmin_email"

    /// The stored value for `account`, or nil when absent.
    static func string(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Upsert `value` for `account`; an empty string clears it.
    static func set(_ value: String, for account: String) {
        guard !value.isEmpty else { remove(account); return }
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
        ]
    }
}
