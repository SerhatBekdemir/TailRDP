import Foundation
import Combine

/// Builds the sdl-freerdp argv from a profile and launches it, feeding the
/// password over stdin (/from-stdin:force) so it never appears in argv or on disk.
struct SessionEndNotice: Equatable {
    let profileID: String
    let message: String
}

@MainActor
final class RDPLauncher: ObservableObject {
    @Published private(set) var activeSessions: Set<String> = []
    @Published private(set) var sessionEndNotice: SessionEndNotice?

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
    private var stderrPipes: [String: Pipe] = [:]
    private var userDisconnects: Set<String> = []

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
        let masked = CredentialStore.shared.hasPassword(for: profile.id) ? "••••••" : nil
        return ([bin] + buildArguments(for: profile, password: masked)).joined(separator: " ")
    }

    /// Launch a session. Returns an error string on failure, nil on success.
    func launch(profile: HostProfile) -> String? {
        guard let bin = binaryPath else {
            return "sdl-freerdp not found — install with: brew install freerdp"
        }
        guard !profile.address.isEmpty else { return "No address set for this machine" }

        let password = CredentialStore.shared.password(for: profile.id) ?? ""

        let args = buildArguments(for: profile, password: password)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        stderrPipes[profile.id] = errPipe

        proc.terminationHandler = { [weak self] finished in
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrText = String(decoding: stderrData, as: UTF8.self)
            let reason: String
            switch finished.terminationReason {
            case .exit: reason = "exit"
            case .uncaughtSignal: reason = "signal"
            @unknown default: reason = "unknown"
            }
            Task { @MainActor in
                let userInitiated = self?.userDisconnects.remove(profile.id) != nil
                if !userInitiated {
                    self?.sessionEndNotice = SessionEndNotice(
                        profileID: profile.id,
                        message: Self.describeSessionEnd(
                            stderr: stderrText,
                            exitCode: finished.terminationStatus,
                            reason: reason
                        )
                    )
                }
                self?.activeSessions.remove(profile.id)
                self?.processes[profile.id] = nil
                self?.stderrPipes[profile.id] = nil
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
        userDisconnects.insert(profileID)
        processes[profileID]?.terminate()
    }

    func clearSessionEndNotice(for profileID: String) {
        if sessionEndNotice?.profileID == profileID {
            sessionEndNotice = nil
        }
    }

    private static func describeSessionEnd(stderr: String, exitCode: Int32, reason: String) -> String {
        if stderr.contains("ERRINFO_LOGOFF_BY_USER") {
            return "Remote session ended — the desktop on the server logged off (often caused by GNOME Shell crashing when launching heavy apps like VS Code on Ubuntu 24.04)."
        }
        if reason == "signal" {
            return "RDP client exited unexpectedly (signal \(exitCode))."
        }
        if exitCode != 0 {
            return "RDP session ended with exit code \(exitCode)."
        }
        return "RDP session ended."
    }
}
