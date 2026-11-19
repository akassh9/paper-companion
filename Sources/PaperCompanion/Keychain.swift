import Foundation
import Security

/// Stores the Claude API key in the login Keychain. The key is never written to disk elsewhere.
enum APIKeyStore {
    private static let service = "Paper Companion"
    private static let account = "anthropic-api-key"

    /// The key, once read, for the rest of this launch: one Keychain access per launch, not one per question.
    nonisolated(unsafe) private static var cached: String?

    static func read() -> String? {
        if let cached { return cached }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        cached = key
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        delete()
        cached = key
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Paper Companion — Claude API key",
            kSecValueData as String: Data(key.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        cached = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
