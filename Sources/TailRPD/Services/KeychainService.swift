import Foundation
import Security

/// Stores RDP passwords in the macOS login Keychain (generic password items),
/// keyed by profile id. Nothing sensitive is ever written to disk in plaintext.
enum KeychainService {
    private static let service = "com.aegis.rdp"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func setPassword(_ password: String, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard !password.isEmpty else { return }
        var add = baseQuery(account)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func hasPassword(account: String) -> Bool {
        password(account: account)?.isEmpty == false
    }

    static func deletePassword(account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
