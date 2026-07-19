import Foundation
import LocalAuthentication
import Security

/// Per-host RDP passwords stored locally in Application Support (not macOS Keychain).
/// Avoids the system "login keychain password" dialog on every ad-hoc app rebuild.
final class CredentialStore {
    static let shared = CredentialStore()
    static let service = "app.tailrdp"

    private let fileURL: URL
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    private init(fileURL: URL, migrateKeychain: Bool) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        loadFromDisk()
        if migrateKeychain { migrateFromKeychainIfNeeded() }
    }

    private convenience init() {
        // Never run Keychain migration against a QA data-dir override.
        self.init(
            fileURL: AppDataDir.base.appendingPathComponent("credentials.json"),
            migrateKeychain: AppDataDir.override == nil
        )
    }

    /// Isolated store for unit tests — does not touch Application Support or Keychain.
    convenience init(testFileURL: URL) {
        self.init(fileURL: testFileURL, migrateKeychain: false)
    }

    func password(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return passwords[id]
    }

    func hasPassword(for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let pwd = passwords[id] else { return false }
        return !pwd.isEmpty
    }

    @discardableResult
    func set(_ password: String, for id: String) -> Bool {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            passwords.removeValue(forKey: id)
        } else {
            passwords[id] = trimmed
        }
        return saveToDisk()
    }

    func remove(for id: String) {
        lock.lock()
        defer { lock.unlock() }
        passwords.removeValue(forKey: id)
        _ = saveToDisk()
    }

    // MARK: - Private

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        passwords = dict
    }

    @discardableResult
    private func saveToDisk() -> Bool {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(passwords)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            return true
        } catch {
            return false
        }
    }

    /// One-time silent import from legacy Keychain items, then delete them so macOS never prompts.
    private func migrateFromKeychainIfNeeded() {
        let flag = "app.tailrdp.keychainMigratedToFile"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        defer { UserDefaults.standard.set(true, forKey: flag) }

        let context = LAContext()
        context.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            importKeychainItems(result)
            if !passwords.isEmpty { _ = saveToDisk() }
        }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }

    private func importKeychainItems(_ result: CFTypeRef?) {
        if let items = result as? [[String: Any]] {
            for item in items { importKeychainItem(item) }
        } else if let item = result as? [String: Any] {
            importKeychainItem(item)
        }
    }

    private func importKeychainItem(_ item: [String: Any]) {
        guard let account = item[kSecAttrAccount as String] as? String,
              let data = item[kSecValueData as String] as? Data,
              let pwd = String(data: data, encoding: .utf8),
              !pwd.isEmpty else { return }
        if passwords[account] == nil {
            passwords[account] = pwd
        }
    }
}
