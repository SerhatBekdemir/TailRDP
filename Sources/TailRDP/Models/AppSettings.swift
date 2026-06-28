import Foundation

/// UserDefaults keys for app-wide preferences (set in the Settings window).
enum AppSettingsKey {
    static let tailscaleBinaryPath = "tailscaleBinaryPath"
    static let freerdpBinaryPath = "freerdpBinaryPath"
    static let defaultUsername = "defaultUsername"
    static let showOffline = "showOffline"
    static let hasCompletedFirstRun = "hasCompletedFirstRun"
}

extension UserDefaults {
    /// Default username applied to newly discovered hosts (empty until wizard or Settings).
    var defaultUsername: String {
        string(forKey: AppSettingsKey.defaultUsername) ?? ""
    }
}
