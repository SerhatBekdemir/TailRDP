import Foundation
import Security

/// Stores per-host RDP passwords in the macOS Keychain (service `app.tailrdp`).
/// Username is part of HostProfile. One-time import from legacy `credentials.json`.
final class CredentialStore {
    static let shared = CredentialStore()
    static let service = "app.tailrdp"

    private let legacyURL: URL

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailRDP", isDirectory: true)
        legacyURL = base.appendingPathComponent("credentials.json")
        migrateFromLegacyJSONIfNeeded()
    }

    private func migrateFromLegacyJSONIfNeeded() {
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (id, pwd) in dict where !pwd.isEmpty {
            if password(for: id) == nil {
                set(pwd, for: id)
            }
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }

    func password(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasPassword(for id: String) -> Bool { !(password(for: id)?.isEmpty ?? true) }

    func set(_ password: String, for id: String) {
        if password.isEmpty {
            remove(for: id)
            return
        }
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    func remove(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(query as CFDictionary)
    }
}
