import Foundation

/// Remote Linux session state and recent errors, discovered over SSH.
public struct RemoteSessionReport: Equatable {
    public var layoutSummary: String
    public var remoteSessionIDs: [String]
    public var recentErrors: [String]

    public init(layoutSummary: String, remoteSessionIDs: [String], recentErrors: [String]) {
        self.layoutSummary = layoutSummary
        self.remoteSessionIDs = remoteSessionIDs
        self.recentErrors = recentErrors
    }

    public var hasErrors: Bool { !recentErrors.isEmpty }
}

/// Recovery actions chosen from remote journal + RDP error codes — applied automatically.
public enum RecoveryPreset: Equatable {
    case none
    case endStuckSessions
    case resetRemoteDesktop
    case useSafeClientSettings
}

/// Whether a remote Linux session is still active, ended, or could not be verified.
public enum RemoteSessionState: Equatable {
    case active
    case inactive
    case unknown
}

public enum RemoteDisplayRecovery {
    static func inspect(_ profile: HostProfile) -> Result<RemoteSessionReport, AppError> {
        guard profile.isLinux else {
            return .success(RemoteSessionReport(layoutSummary: "Not a Linux host", remoteSessionIDs: [], recentErrors: []))
        }
        return runReportScript(profile, sinceMinutes: nil)
    }

    static func discoverFailure(_ profile: HostProfile) -> Result<RemoteSessionReport, AppError> {
        guard profile.isLinux else {
            return .success(RemoteSessionReport(layoutSummary: "", remoteSessionIDs: [], recentErrors: []))
        }
        return runReportScript(profile, sinceMinutes: 5)
    }

    public static func chooseRecovery(errInfo: String?, report: RemoteSessionReport?, failureCount: Int) -> RecoveryPreset {
        if let errInfo, isBenignDisconnect(errInfo) { return .none }

        let errors = (report?.recentErrors ?? []).joined(separator: "\n")
        let combined = [errInfo ?? "", errors].joined(separator: "\n").lowercased()

        if combined.contains("segv")
            || (combined.contains("gnome-shell") && combined.contains("signal")) {
            return .resetRemoteDesktop
        }
        if combined.contains("rdp server stopped") && failureCount >= 2 {
            return .resetRemoteDesktop
        }
        if (report?.remoteSessionIDs.count ?? 0) > 1 {
            return .endStuckSessions
        }
        if errInfo == "ERRINFO_SERVER_SHUTDOWN" {
            return failureCount >= 2 ? .resetRemoteDesktop : .endStuckSessions
        }
        if failureCount >= 2 {
            return .useSafeClientSettings
        }
        return .none
    }

    private static func isBenignDisconnect(_ code: String) -> Bool {
        switch code {
        case "ERRINFO_LOGOFF_BY_USER",
             "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION":
            return true
        default:
            return false
        }
    }

    public static func looksLikeRecentCrash(_ report: RemoteSessionReport) -> Bool {
        let combined = report.recentErrors.joined(separator: "\n").lowercased()
        return combined.contains("segv")
            || combined.contains("core dumped")
            || (combined.contains("gnome-shell") && combined.contains("signal"))
            || (combined.contains("gnome-remote-de") && combined.contains("stopped")
                && combined.contains("segv"))
    }

    static func remoteSessionState(_ profile: HostProfile) -> RemoteSessionState {
        guard profile.isLinux else { return .inactive }
        switch inspect(profile) {
        case .failure:
            return .unknown
        case .success(let report):
            return report.remoteSessionIDs.isEmpty ? .inactive : .active
        }
    }

    static func hasActiveRemoteSession(_ profile: HostProfile) -> Bool {
        remoteSessionState(profile) == .active
    }

    static func apply(_ preset: RecoveryPreset, profile: HostProfile) -> Result<String, AppError> {
        switch preset {
        case .none: return .success("")
        case .endStuckSessions: return terminateRemoteSessions(profile)
        case .resetRemoteDesktop: return recover(profile)
        case .useSafeClientSettings: return .success("will use fallback display settings")
        }
    }

    static func terminateRemoteSessions(_ profile: HostProfile, exceptSessionID: String? = nil) -> Result<String, AppError> {
        guard profile.isLinux else { return .fail("Only applies to Linux hosts") }
        let script = RemoteScriptLoader.terminateSessionsScript(exceptSessionID: exceptSessionID)
        let res = SFTPService.runScript(profile, script: script)
        if !res.ok && !res.stdout.contains("__RECOVER__ok") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "Could not end remote sessions (exit \(res.exitCode))" : msg)
        }
        let n = parseValue(res.stdout, key: "terminated", namespace: "RECOVER") ?? "0"
        return .success(n == "0" ? "cleared connection state" : "ended \(n) stuck remote session(s)")
    }

    static func recover(_ profile: HostProfile) -> Result<String, AppError> {
        guard profile.isLinux else { return .fail("Session recovery only applies to Linux hosts") }
        let res = SFTPService.runScript(profile, script: RemoteScriptLoader.recoverScript())
        if !res.ok && !res.stdout.contains("__RECOVER__ok") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "SSH recovery failed (exit \(res.exitCode))" : msg)
        }
        let backup = parseValue(res.stdout, key: "backup", namespace: "RECOVER") ?? ""
        let terminated = parseValue(res.stdout, key: "terminated", namespace: "RECOVER") ?? "0"
        var parts: [String] = []
        if backup != "none", !backup.isEmpty { parts.append("reset remote display config") }
        if terminated != "0" { parts.append("ended \(terminated) remote session(s)") }
        if parts.isEmpty { parts.append("remote session reset") }
        return .success(parts.joined(separator: ", "))
    }

    static func plainRecoveryLabel(_ preset: RecoveryPreset) -> String {
        switch preset {
        case .none: return ""
        case .endStuckSessions: return "Cleared a stuck remote session"
        case .resetRemoteDesktop: return "Reset the remote desktop session"
        case .useSafeClientSettings: return "Switched to fallback display settings"
        }
    }

    private static func runReportScript(_ profile: HostProfile, sinceMinutes: Int?) -> Result<RemoteSessionReport, AppError> {
        let res = SFTPService.runScript(profile, script: RemoteScriptLoader.reportScript(sinceMinutes: sinceMinutes))
        if !res.ok && !res.stdout.contains("__REPORT__") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "SSH inspect failed (exit \(res.exitCode))" : msg)
        }
        let errors = parseValue(res.stdout, key: "errors")?
            .split(separator: "|||").map(String.init).filter { !$0.isEmpty } ?? []
        return .success(RemoteSessionReport(
            layoutSummary: parseValue(res.stdout, key: "layout") ?? "unknown",
            remoteSessionIDs: parseValue(res.stdout, key: "sessions")?
                .split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? [],
            recentErrors: errors
        ))
    }

    private static func parseValue(_ stdout: String, key: String, namespace: String = "REPORT") -> String? {
        let marker = "__\(namespace)__\(key)="
        guard let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        return String(line.dropFirst(marker.count))
    }
}
