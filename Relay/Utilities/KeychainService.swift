import Foundation
import Security

/// Stores API keys in the macOS Keychain, one item per provider.
///
/// Keys are never written to disk by this app, never logged, and never
/// embedded in source.
enum KeychainService {
    static let defaultService = "co.kevel.Relay"
    /// Keys saved before the app was renamed. Read once and migrated, so the
    /// rename doesn't quietly lose someone's API key.
    private static let legacyService = "co.kevel.LiveTranslator"

    private static func baseQuery(_ account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: TranslationProvider,
                           service: String = defaultService) -> Bool {
        let account = provider.keychainAccount
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return deleteAPIKey(for: provider, service: service) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Try updating an existing item before adding a new one.
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(baseQuery(account, service: service) as CFDictionary, update) == errSecSuccess {
            Log.info(.keychain, "\(provider.displayName) API key updated")
            return true
        }

        var query = baseQuery(account, service: service)
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

    static func loadAPIKey(for provider: TranslationProvider,
                           service: String = defaultService) -> String? {
        if let key = read(account: provider.keychainAccount, service: service) { return key }
        guard service == defaultService else { return nil }

        // Fall back to the pre-rename item, then move it across so this only
        // ever happens once.
        guard let legacy = read(account: provider.keychainAccount, service: legacyService) else {
            return nil
        }
        Log.info(.keychain, "Migrating \(provider.displayName) key from the previous app name")
        saveAPIKey(legacy, for: provider)
        return legacy
    }

    private static func read(account: String, service: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func hasAPIKey(for provider: TranslationProvider,
                          service: String = defaultService) -> Bool {
        loadAPIKey(for: provider, service: service) != nil
    }

    @discardableResult
    static func deleteAPIKey(for provider: TranslationProvider,
                             service: String = defaultService) -> Bool {
        let status = SecItemDelete(baseQuery(provider.keychainAccount, service: service) as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if ok { Log.info(.keychain, "\(provider.displayName) API key removed") }
        return ok
    }
}
