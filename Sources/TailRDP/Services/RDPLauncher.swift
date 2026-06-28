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
        // FreeRDP auto-reconnect fights window-close / pause; only opt in explicitly.
        if s.autoReconnect { a.append("+auto-reconnect") }
        return a
    }

    func previewCommand(for profile: HostProfile) -> String {
        let bin = (binaryPath as NSString?)?.lastPathComponent ?? "sdl-freerdp"
        let masked = CredentialStore.shared.hasPassword(for: profile.id) ? "••••••" : nil
        return ([bin] + buildArguments(for: profile, password: masked)).joined(separator: " ")
    }

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
                let started = self?.sessionStartedAt[profile.id] ?? Date()
                let duration = Date().timeIntervalSince(started)
                let loggedOut = self?.userDisconnects.remove(profile.id) != nil
                let end = Self.classifySessionEnd(
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

    private struct SessionEndClassification {
        let kind: SessionEndKind
        let message: String
        let errInfoCode: String?
    }

    private static func classifySessionEnd(
        loggedOut: Bool,
        stderr: String,
        exitCode: Int32,
        reason: String
    ) -> SessionEndClassification {
        if loggedOut {
            return SessionEndClassification(kind: .loggedOut, message: "Disconnected.", errInfoCode: nil)
        }
        let errInfo = firstMatch(in: stderr, pattern: #"ERRINFO_[A-Z0-9_]+"#)
        if let errInfo {
            if errInfo == "ERRINFO_LOGOFF_BY_USER" {
                return SessionEndClassification(
                    kind: .paused,
                    message: "Session paused. Your work is still running — connect again to resume.",
                    errInfoCode: errInfo
                )
            }
            if errInfo == "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION" {
                return SessionEndClassification(
                    kind: .paused,
                    message: "Session paused. Another client took over — connect again to resume.",
                    errInfoCode: errInfo
                )
            }
            return SessionEndClassification(kind: .crashed, message: rdpErrorLabel(errInfo), errInfoCode: errInfo)
        }
        if isClientWindowClosed(exitCode: exitCode, reason: reason, stderr: stderr) {
            return SessionEndClassification(
                kind: .paused,
                message: "Session paused. Connect again to resume.",
                errInfoCode: nil
            )
        }
        if reason == "signal" {
            return SessionEndClassification(
                kind: .crashed,
                message: "Connection interrupted unexpectedly.",
                errInfoCode: nil
            )
        }
        if exitCode != 0 {
            return SessionEndClassification(
                kind: .crashed,
                message: "Connection ended unexpectedly (code \(exitCode)).",
                errInfoCode: nil
            )
        }
        return SessionEndClassification(
            kind: .paused,
            message: "Session paused. Connect again to resume.",
            errInfoCode: nil
        )
    }

    /// macOS window close (red button) often exits with 128+signal and no RDP error in stderr.
    private static func isClientWindowClosed(exitCode: Int32, reason: String, stderr: String) -> Bool {
        // 128 + SIGINT(2), SIGQUIT(3), SIGTERM(15) — typical when closing an SDL window.
        let windowCloseCodes: Set<Int32> = [130, 131, 143, 2, 3, 15]
        if windowCloseCodes.contains(exitCode) { return true }
        if reason == "signal", exitCode == 0 || windowCloseCodes.contains(exitCode) { return true }
        // Clean window close with no protocol error in stderr.
        if exitCode != 0, stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return false
    }

    private static func rdpErrorLabel(_ code: String) -> String {
        switch code {
        case "ERRINFO_LOGOFF_BY_USER": return "The remote desktop closed the session."
        case "ERRINFO_SERVER_SHUTDOWN": return "The remote computer shut down."
        case "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION": return "Another connection took over this session."
        default: return "The remote session ended (\(code))."
        }
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }
}
