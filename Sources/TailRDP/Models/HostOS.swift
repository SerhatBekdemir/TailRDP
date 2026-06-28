import Foundation

/// Supported host OS values for RDP profiles (matches manual Add Host picker).
enum HostOS: String, Codable, CaseIterable, Sendable {
    case linux
    case windows
    case macOS
    case other

    static let supportedRawValues: Set<String> = Set(allCases.map(\.rawValue))

    /// Map Tailscale or stored strings to a supported OS, or nil when not RDP-applicable.
    static func normalize(_ raw: String) -> HostOS? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "linux": return .linux
        case "windows": return .windows
        case "macos", "darwin": return .macOS
        case "other": return .other
        default: return nil
        }
    }

    /// Whether a tailnet peer should appear in the sidebar (desktop RDP targets only).
    static func isTailscaleRDPCandidate(os raw: String, isSelf: Bool) -> Bool {
        !isSelf && normalize(raw) != nil
    }

    /// Whether a persisted profile meets the allowed OS definition.
    static func isAllowedProfile(_ raw: String) -> Bool {
        normalize(raw) != nil
    }
}
