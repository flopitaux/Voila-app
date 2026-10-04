import Foundation
import Security

/// Tiny wrapper around generic-password Keychain items.
enum Keychain {
    private static let service = "com.lopitaux.Voila"

    #if DEBUG
    /// Demo/screenshot runs are ad-hoc signed; touching the real Keychain would trigger
    /// macOS password prompts, so they get an empty, in-memory keychain instead.
    private static let disabled = ProcessInfo.processInfo.environment["VOILA_DEMO"] == "1"
    #else
    private static let disabled = false
    #endif

    static func set(_ value: String?, for account: String) {
        guard !disabled else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        guard !disabled else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
