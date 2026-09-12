import Foundation
import Security

/// Stores API keys in the macOS Keychain, one item per provider.
///
/// Keys are never written to disk by this app, never logged, and never
/// embedded in source.
enum KeychainService {
    private static let service = "co.kevel.LiveTranslator"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: TranslationProvider) -> Bool {
        let account = provider.keychainAccount
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteAPIKey(for: provider) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Try updating an existing item before adding a new one.
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(baseQuery(account) as CFDictionary, update) == errSecSuccess {
            Log.info(.keychain, "\(provider.displayName) API key updated")
            return true
        }

        var query = baseQuery(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            Log.info(.keychain, "\(provider.displayName) API key saved")
            return true
        }
        Log.error(.keychain, "Could not save \(provider.displayName) API key (OSStatus \(status))")
        return false
    }

    static func loadAPIKey(for provider: TranslationProvider) -> String? {
        var query = baseQuery(provider.keychainAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func hasAPIKey(for provider: TranslationProvider) -> Bool {
        loadAPIKey(for: provider) != nil
    }

    @discardableResult
    static func deleteAPIKey(for provider: TranslationProvider) -> Bool {
        let status = SecItemDelete(baseQuery(provider.keychainAccount) as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if ok { Log.info(.keychain, "\(provider.displayName) API key removed") }
        return ok
    }
}
