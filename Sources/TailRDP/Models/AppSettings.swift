import Foundation

/// UserDefaults keys for app-wide preferences (set in the Settings window).
enum AppSettingsKey {
    static let tailscaleBinaryPath = "tailscaleBinaryPath"
    static let freerdpBinaryPath = "freerdpBinaryPath"
    static let defaultUsername = "defaultUsername"
    static let showOffline = "showOffline"
    static let hasCompletedFirstRun = "hasCompletedFirstRun"
    static let dismissedDependencyWarning = "dismissedDependencyWarning"
}

/// Data directory for profiles.json / credentials.json.
/// `TAILRDP_DATA_DIR` env overrides for QA runs against sanitized data (macOS ignores $HOME).
enum AppDataDir {
    static var override: URL? {
        guard let p = ProcessInfo.processInfo.environment["TAILRDP_DATA_DIR"], !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    static var base: URL {
        override ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailRDP", isDirectory: true)
    }
}

extension UserDefaults {
    /// Default username applied to newly discovered hosts (empty until wizard or Settings).
    var defaultUsername: String {
        string(forKey: AppSettingsKey.defaultUsername) ?? ""
    }
}

extension Notification.Name {
    static let showAboutWindow = Notification.Name("TailRDPShowAbout")
}
