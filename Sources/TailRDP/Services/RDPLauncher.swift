import Foundation
import Combine

/// Builds the sdl-freerdp argv from a profile and launches it, feeding the
/// password over stdin (/from-stdin:force) so it never appears in argv or on disk.
struct SessionEndNotice: Equatable {
    let profileID: String
    let message: String
    var endKind: SessionEndKind = .paused
    var errInfoCode: String?
    var durationSeconds: TimeInterval = 0
    var userInitiated: Bool = false

    var abnormalEnd: Bool { endKind == .crashed }
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
    private var sessionStartedAt: [String: Date] = [:]
    private var sessionSettingsUsed: [String: RDPSettings] = [:]
    /// Bumped before each launch so stale termination handlers from a prior client are ignored.
    private var sessionGeneration: [String: UInt64] = [:]

    func isActive(_ id: String) -> Bool { activeSessions.contains(id) }

    func lastUsedSettings(for profileID: String) -> RDPSettings? {
        sessionSettingsUsed[profileID]
    }

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
        // Gnome Remote Desktop: auto-reconnect causes black-screen stalls after pause.
        if s.autoReconnect, profile.os != "linux" { a.append("+auto-reconnect") }
        return a
    }

    func previewCommand(for profile: HostProfile) -> String {
        let bin = (binaryPath as NSString?)?.lastPathComponent ?? "sdl-freerdp"
        let masked = CredentialStore.shared.hasPassword(for: profile.id) ? "••••••" : nil
        return ([bin] + buildArguments(for: profile, password: masked)).joined(separator: " ")
    }

    func launch(profile: HostProfile) async -> String? {
        guard let bin = binaryPath else {
            return "sdl-freerdp not found — install with: brew install freerdp"
        }
        guard !profile.address.isEmpty else { return "No address set for this machine" }

        // Bump generation before killing any prior client so its termination handler is ignored.
        let generation = (sessionGeneration[profile.id] ?? 0) + 1
        sessionGeneration[profile.id] = generation

        // Drop a stuck local client before opening a new connection to the same host.
        await terminateClients(to: profile)

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
                guard self?.sessionGeneration[profile.id] == generation else { return }
                let started = self?.sessionStartedAt[profile.id] ?? Date()
                let duration = Date().timeIntervalSince(started)
                let loggedOut = self?.userDisconnects.remove(profile.id) != nil
                let end = SessionEndClassifier.classify(
                    loggedOut: loggedOut,
                    stderr: stderrText,
                    exitCode: finished.terminationStatus,
                    reason: reason
                )
                self?.sessionEndNotice = SessionEndNotice(
                    profileID: profile.id,
                    message: end.message,
                    endKind: end.kind,
                    errInfoCode: end.errInfoCode,
                    durationSeconds: duration,
                    userInitiated: loggedOut
                )
                self?.activeSessions.remove(profile.id)
                self?.processes[profile.id] = nil
                self?.stderrPipes[profile.id] = nil
                self?.sessionStartedAt[profile.id] = nil
            }
        }

        do { try proc.run() } catch {
            return "launch failed: \(error.localizedDescription)"
        }

        processes[profile.id] = proc
        activeSessions.insert(profile.id)
        sessionStartedAt[profile.id] = Date()
        sessionSettingsUsed[profile.id] = profile.settings
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

    /// End any local FreeRDP client still connected to this host (including orphans from a prior app run).
    private func terminateClients(to profile: HostProfile) async {
        let tracked = processes[profile.id]
        let target = profile.address.isEmpty ? nil : "/v:\(profile.address):\(profile.rdpPort)"
        activeSessions.remove(profile.id)
        processes[profile.id] = nil
        stderrPipes[profile.id] = nil
        sessionStartedAt[profile.id] = nil

        await Task.detached {
            if let tracked {
                tracked.terminate()
                tracked.waitUntilExit()
            }
            guard let target else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            proc.arguments = ["-f", target]
            try? proc.run()
            proc.waitUntilExit()
            try? await Task.sleep(for: .milliseconds(250))
        }.value
    }
}
