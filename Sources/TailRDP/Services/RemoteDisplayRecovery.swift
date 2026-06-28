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
        guard profile.os == "linux" else {
            return .success(RemoteSessionReport(layoutSummary: "Not a Linux host", remoteSessionIDs: [], recentErrors: []))
        }
        return runReportScript(profile, sinceMinutes: nil)
    }

    static func discoverFailure(_ profile: HostProfile) -> Result<RemoteSessionReport, AppError> {
        guard profile.os == "linux" else {
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
        guard profile.os == "linux" else { return .inactive }
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

    static func terminateRemoteSessions(_ profile: HostProfile) -> Result<String, AppError> {
        guard profile.os == "linux" else { return .fail("Only applies to Linux hosts") }
        let res = SFTPService.runScript(profile, script: terminateSessionsScript)
        if !res.ok && !res.stdout.contains("__RECOVER__ok") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "Could not end remote sessions (exit \(res.exitCode))" : msg)
        }
        let n = parseValue(res.stdout, key: "terminated", namespace: "RECOVER") ?? "0"
        return .success(n == "0" ? "cleared connection state" : "ended \(n) stuck remote session(s)")
    }

    static func recover(_ profile: HostProfile) -> Result<String, AppError> {
        guard profile.os == "linux" else { return .fail("Session recovery only applies to Linux hosts") }
        let res = SFTPService.runScript(profile, script: recoverScript)
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

    private static let terminateSessionsScript = """
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    TERMINATED=0
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
      [ -n "$sid" ] || continue
      remote=$(loginctl show-session "$sid" -p Remote --value 2>/dev/null)
      type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
      user=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
      if [ "$remote" = yes ] && [ "$type" = wayland ] && [ "$user" = "$(id -u)" ]; then
        if loginctl terminate-session "$sid" 2>/dev/null; then
          TERMINATED=$((TERMINATED+1))
        fi
      fi
    done
    echo "__RECOVER__ok=1"
    echo "__RECOVER__terminated=$TERMINATED"
    """

    private static func runReportScript(_ profile: HostProfile, sinceMinutes: Int?) -> Result<RemoteSessionReport, AppError> {
        let res = SFTPService.runScript(profile, script: reportScript(sinceMinutes: sinceMinutes))
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

    private static func reportScript(sinceMinutes: Int?) -> String {
        let envPrefix = sinceMinutes.map { "SINCE_MINUTES=\($0) " } ?? ""
        return """
        \(envPrefix)python3 - <<'PY'
        import os, subprocess, xml.etree.ElementTree as ET

        since = os.environ.get("SINCE_MINUTES", "").strip()
        layout_parts = []
        mon_path = os.path.join(os.path.expanduser("~"), ".config", "monitors.xml")
        if os.path.isfile(mon_path):
            try:
                root = ET.parse(mon_path).getroot()
                for cfg in root.findall("configuration"):
                    for logical in cfg.findall("logicalmonitor"):
                        scale_el = logical.find("scale")
                        scale = float(scale_el.text) if scale_el is not None and scale_el.text else 1.0
                        connectors = [
                            m.find("connector").text
                            for m in logical.findall("monitor")
                            if m.find("connector") is not None and m.find("connector").text
                        ]
                        mode = logical.find(".//mode")
                        wh = ""
                        if mode is not None:
                            w, h = mode.find("width"), mode.find("height")
                            if w is not None and h is not None and w.text and h.text:
                                wh = f" {w.text}x{h.text}"
                        names = ",".join(connectors) if connectors else "remote"
                        layout_parts.append(f"{names}{wh} @{scale:g}x")
            except Exception as e:
                layout_parts.append(f"monitors.xml: {e}")
        else:
            layout_parts.append("default layout")

        uid = os.getuid()
        remote_ids = []
        try:
            out = subprocess.check_output(["loginctl", "list-sessions", "--no-legend"], text=True)
            for line in out.splitlines():
                parts = line.split()
                if not parts:
                    continue
                sid = parts[0]
                show = subprocess.check_output(
                    ["loginctl", "show-session", sid, "-p", "Remote", "-p", "Type", "-p", "User"],
                    text=True
                )
                fields = dict(ln.split("=", 1) for ln in show.splitlines() if "=" in ln)
                if fields.get("Remote") == "yes" and fields.get("Type") == "wayland":
                    if fields.get("User", "").strip() == str(uid):
                        remote_ids.append(sid)
        except Exception:
            pass

        errors = []
        if since:
            journal_args = ["journalctl", "--user", "-n", "60", "--no-pager", f"--since={since} min ago"]
            system_args = ["journalctl", "-n", "80", "--no-pager", f"--since={since} min ago"]

            def collect(args, keywords):
                try:
                    out = subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
                    for line in out.splitlines():
                        s = line.strip()
                        if not s or s.startswith("-- "):
                            continue
                        if keywords and not any(k in s for k in keywords):
                            continue
                        errors.append(s[-240:])
                except Exception:
                    pass

            collect(journal_args, ("ERROR", "ERR", "SEGV", "failed", "crash", "RDP"))
            collect(system_args, ("gnome-shell", "gnome-remote-de", "SEGV", "RDP server"))

        print(f"__REPORT__layout={' | '.join(layout_parts) if layout_parts else 'none'}")
        print(f"__REPORT__sessions={','.join(remote_ids)}")
        print("__REPORT__errors=" + "|||".join(errors[-8:]))
        PY
        """
    }

    private static let recoverScript = """
    set -e
    MON="$HOME/.config/monitors.xml"
    BACKUP="none"
    if [ -f "$MON" ]; then
      BACKUP="$MON.bak-$(date +%Y%m%d-%H%M%S)"
      cp "$MON" "$BACKUP"
      rm -f "$MON"
    fi
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    TERMINATED=0
    for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
      [ -n "$sid" ] || continue
      remote=$(loginctl show-session "$sid" -p Remote --value 2>/dev/null)
      type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
      user=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
      if [ "$remote" = yes ] && [ "$type" = wayland ] && [ "$user" = "$(id -u)" ]; then
        if loginctl terminate-session "$sid" 2>/dev/null; then
          TERMINATED=$((TERMINATED+1))
        fi
      fi
    done
    echo "__RECOVER__ok=1"
    echo "__RECOVER__backup=$BACKUP"
    echo "__RECOVER__terminated=$TERMINATED"
    """

    private static func parseValue(_ stdout: String, key: String, namespace: String = "REPORT") -> String? {
        let marker = "__\(namespace)__\(key)="
        guard let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        return String(line.dropFirst(marker.count))
    }
}
