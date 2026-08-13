import Foundation

enum AppIdentity {
    static let baseName = "TailRDP"
    static let fallbackVersion = "1.0.2"

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallbackVersion
    }

    static var displayName: String {
        "\(baseName) \(version)"
    }
}

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

/// Applies command-line state overrides only to isolated QA runs.
///
/// The QA inventory uses these flags to make a fixture run reproducible without
/// changing a normal user's preferences. The data-directory guard prevents the
/// flags from mutating the production profile store.
enum AppLaunchOverrides {
    static func applyForQA() {
        guard AppDataDir.override != nil else { return }
        let arguments = CommandLine.arguments
        for (argument, key) in [
            ("-hasCompletedFirstRun", AppSettingsKey.hasCompletedFirstRun),
            ("-showOffline", AppSettingsKey.showOffline)
        ] {
            guard let index = arguments.firstIndex(of: argument),
                  index + 1 < arguments.count,
                  let value = parseBool(arguments[index + 1]) else { continue }
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
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
