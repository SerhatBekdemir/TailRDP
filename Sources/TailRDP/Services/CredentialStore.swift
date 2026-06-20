import Foundation

/// Stores per-host RDP passwords in a 0600 JSON file in Application Support.
/// No Keychain → no system password popups. Username is part of HostProfile.
final class CredentialStore {
    static let shared = CredentialStore()

    private let url: URL
    private var creds: [String: String]   // profile.id -> password

    private init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailRDP", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("credentials.json")
        creds = Self.load(url)
    }

    private static func load(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func password(for id: String) -> String? { creds[id] }

    func hasPassword(for id: String) -> Bool { !(creds[id]?.isEmpty ?? true) }

    func set(_ password: String, for id: String) {
        if password.isEmpty { creds[id] = nil } else { creds[id] = password }
        persist()
    }

    func remove(for id: String) {
        creds[id] = nil
        persist()
    }
}
