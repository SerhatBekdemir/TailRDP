import Foundation

/// UserDefaults keys for app-wide preferences (set in the Settings window).
enum AppSettingsKey {
    static let tailscaleBinaryPath = "tailscaleBinaryPath"
    static let defaultUsername = "defaultUsername"
    static let showOffline = "showOffline"
}

extension UserDefaults {
    /// Default username applied to newly discovered hosts (falls back to "aegis").
    var defaultUsername: String {
        let v = string(forKey: AppSettingsKey.defaultUsername) ?? ""
        return v.isEmpty ? "aegis" : v
    }
}
