import Foundation

/// Detects external CLI dependencies TailRDP relies on.
enum DependencyChecker {
    private static var cachedTailscale: (found: Bool, path: String?)?
    private static var cachedFreerdp: (found: Bool, path: String?)?
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
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (true, override)
        }
        lock.lock()
        if let cached = cachedTailscale {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let result: (found: Bool, path: String?)
        if let path = tailscaleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            result = (true, path)
        } else {
            result = (false, nil)
        }
        lock.lock()
        cachedTailscale = result
        lock.unlock()
        return result
    }

    static func freerdp(override: String? = nil) -> (found: Bool, path: String?) {
        if let override, !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return (true, override)
        }
        lock.lock()
        if let cached = cachedFreerdp {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let result: (found: Bool, path: String?)
        if let path = freerdpCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            result = (true, path)
        } else {
            result = (false, nil)
        }
        lock.lock()
        cachedFreerdp = result
        lock.unlock()
        return result
    }

    static func invalidateCache() {
        lock.lock()
        cachedTailscale = nil
        cachedFreerdp = nil
        lock.unlock()
    }

    static func sshFound() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")
    }
}
