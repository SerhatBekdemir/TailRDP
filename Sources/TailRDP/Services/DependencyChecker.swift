import Foundation

/// Detects external CLI dependencies TailRDP relies on.
enum DependencyChecker {
    static let tailscaleCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale"
    ]

    static let freerdpCandidates = [
        "/opt/homebrew/bin/sdl-freerdp",
        "/usr/local/bin/sdl-freerdp",
        "/opt/homebrew/bin/xfreerdp",
        "/usr/local/bin/xfreerdp"
    ]

    static func tailscale(override: String? = nil) -> (found: Bool, path: String?) {
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (true, override)
        }
        if let path = tailscaleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (true, path)
        }
        return (false, nil)
    }

    static func freerdp(override: String? = nil) -> (found: Bool, path: String?) {
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (true, override)
        }
        if let path = freerdpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (true, path)
        }
        return (false, nil)
    }

    static func sshFound() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
    }
}
