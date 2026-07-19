import Foundation

/// Detects external CLI dependencies TailRDP relies on.
enum DependencyChecker {
    private static var cache: [String: (found: Bool, path: String?)] = [:]
    private static let lock = NSLock()

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
        detect("tailscale", override: override, candidates: tailscaleCandidates)
    }

    static func freerdp(override: String? = nil) -> (found: Bool, path: String?) {
        detect("freerdp", override: override, candidates: freerdpCandidates)
    }

    private static func detect(
        _ key: String,
        override: String?,
        candidates: [String]
    ) -> (found: Bool, path: String?) {
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (true, override)
        }
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let result = (found: path != nil, path: path)
        lock.lock()
        cache[key] = result
        lock.unlock()
        return result
    }

    static func invalidateCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    static func sshFound() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
    }
}
