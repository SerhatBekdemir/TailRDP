import Foundation
import Combine

/// Builds the sdl-freerdp argv from a profile and launches it, feeding the
/// password over stdin (/from-stdin:force) so it never appears in argv or on disk.
@MainActor
final class RDPLauncher: ObservableObject {
    @Published private(set) var activeSessions: Set<String> = []

    private static let binaryCandidates = [
        "/opt/homebrew/bin/sdl-freerdp",
        "/usr/local/bin/sdl-freerdp",
        "/opt/homebrew/bin/xfreerdp",
        "/usr/local/bin/xfreerdp"
    ]

    var binaryPath: String? {
        Self.binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var processes: [String: Process] = [:]

    func isActive(_ id: String) -> Bool { activeSessions.contains(id) }

    /// Build argv. When `password` is non-nil it is inserted as `/p:` — FreeRDP
    /// scrubs this from its own process title immediately after launch, and it
    /// never touches disk or shell history (Process uses execve, not a shell).
    func buildArguments(for profile: HostProfile, password: String?) -> [String] {
        let s = profile.settings
        var a: [String] = [
            "/v:\(profile.address):\(profile.rdpPort)",
            "/u:\(profile.rdpUsername)"
        ]
        if let password, !password.isEmpty { a.append("/p:\(password)") }
        a += [
            "/sec:nla",
            "/cert:ignore",
            "/network:\(s.network.flag)",
            "/gfx:\(s.codec.flag)",
            "/bpp:\(s.bpp)"
        ]
        if s.dynamicResolution {
            a.append("/dynamic-resolution")
        } else {
            a.append("/size:\(s.width)x\(s.height)")
        }
        if s.fullscreen { a.append("/f") }
        if s.multiMonitor { a.append("/multimon") }
        a.append(s.clipboard ? "+clipboard" : "-clipboard")
        if s.sound { a.append("/sound") }
        if s.mapCmdToCtrl { a.append("/kbd:remap:0x15b=0x1d,remap:0x15c=0x1d") }
        if s.autoReconnect { a.append("+auto-reconnect") }
        return a
    }

    /// Human-readable command for the UI preview, with the password masked.
    func previewCommand(for profile: HostProfile) -> String {
        let bin = (binaryPath as NSString?)?.lastPathComponent ?? "sdl-freerdp"
        let masked = KeychainService.hasPassword(account: profile.id) ? "••••••" : nil
        return ([bin] + buildArguments(for: profile, password: masked)).joined(separator: " ")
    }

    /// Launch a session. Returns an error string on failure, nil on success.
    func launch(profile: HostProfile) -> String? {
        guard let bin = binaryPath else {
            return "sdl-freerdp not found — install with: brew install freerdp"
        }
        guard !profile.address.isEmpty else { return "No address set for this machine" }

        let password = KeychainService.password(account: profile.id) ?? ""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = buildArguments(for: profile, password: password)
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.activeSessions.remove(profile.id)
                self?.processes[profile.id] = nil
            }
        }

        do { try proc.run() } catch {
            return "launch failed: \(error.localizedDescription)"
        }

        processes[profile.id] = proc
        activeSessions.insert(profile.id)
        return nil
    }

    func disconnect(profileID: String) {
        processes[profileID]?.terminate()
    }
}
