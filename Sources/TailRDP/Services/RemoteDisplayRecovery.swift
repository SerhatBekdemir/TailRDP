import Foundation

/// GNOME remote-desktop (Meta-* virtual monitor) can pin an unusable layout in
/// `~/.config/monitors.xml` — e.g. 2560×1440 at 200% scale — that persists
/// across reconnects until the file is removed and the remote session restarted.
struct RemoteDisplayReport: Equatable {
    var monitorsFileExists: Bool
    var riskyLayout: Bool
    var maxMetaScale: Double
    var remoteSessionIDs: [String]
    var detail: String

    var needsRecovery: Bool { riskyLayout }
}

enum RemoteDisplayRecovery {
    /// Minimum Meta monitor scale that makes a remote session effectively unusable.
    private static let riskyScaleThreshold = 2.0

    /// Inspect the remote user's GNOME monitor config and active remote sessions.
    static func inspect(_ profile: HostProfile) -> Result<RemoteDisplayReport, AppError> {
        guard profile.os == "linux" else {
            return .success(RemoteDisplayReport(
                monitorsFileExists: false,
                riskyLayout: false,
                maxMetaScale: 1,
                remoteSessionIDs: [],
                detail: "Not a Linux host"
            ))
        }
        let res = SFTPService.runScript(profile, script: inspectScript)
        if !res.ok && !res.stdout.contains("__REPORT__") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "SSH inspect failed (exit \(res.exitCode))" : msg)
        }
        return .success(parseReport(res.stdout))
    }

    /// Back up and remove `monitors.xml`, then terminate stuck remote Wayland sessions.
    static func recover(_ profile: HostProfile) -> Result<String, AppError> {
        guard profile.os == "linux" else { return .fail("Display recovery only applies to Linux hosts") }
        let res = SFTPService.runScript(profile, script: recoverScript)
        if !res.ok && !res.stdout.contains("__RECOVER__ok") {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "SSH recovery failed (exit \(res.exitCode))" : msg)
        }
        let backup = parseValue(res.stdout, key: "backup", namespace: "RECOVER") ?? ""
        let terminated = parseValue(res.stdout, key: "terminated", namespace: "RECOVER") ?? "0"
        var parts: [String] = []
        if !backup.isEmpty { parts.append("backed up monitors.xml") }
        if terminated != "0" { parts.append("ended \(terminated) remote session(s)") }
        if parts.isEmpty { parts.append("remote display reset") }
        return .success(parts.joined(separator: ", "))
    }

    /// Inspect and recover when needed — intended to run before RDP connect.
    static func recoverIfNeeded(_ profile: HostProfile) -> Result<String?, AppError> {
        switch inspect(profile) {
        case .failure(let err): return .failure(err)
        case .success(let report) where !report.needsRecovery:
            return .success(nil)
        case .success:
            switch recover(profile) {
            case .failure(let err): return .failure(err)
            case .success(let summary): return .success(summary)
            }
        }
    }

    // MARK: - Remote scripts

    private static let inspectScript = """
    python3 - <<'PY'
    import os, re, subprocess, xml.etree.ElementTree as ET

    home = os.path.expanduser("~")
    mon_path = os.path.join(home, ".config", "monitors.xml")
    exists = os.path.isfile(mon_path)
    risky = False
    max_scale = 1.0
    detail_parts = []

    if exists:
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
                    meta = [c for c in connectors if c and c.startswith("Meta")]
                    if meta:
                        max_scale = max(max_scale, scale)
                        w = logical.find("width")
                        h = logical.find("height")
                        wh = ""
                        if w is not None and h is not None and w.text and h.text:
                            wh = f" {w.text}x{h.text}"
                        detail_parts.append(f"{meta[0]}{wh} @{scale:g}x")
                        if scale >= \(riskyScaleThreshold):
                            risky = True
        except Exception as e:
            detail_parts.append(f"parse error: {e}")

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
            fields = dict(
                ln.split("=", 1) for ln in show.splitlines() if "=" in ln
            )
            if fields.get("Remote") == "yes" and fields.get("Type") == "wayland":
                if fields.get("User", "").strip() == str(uid):
                    remote_ids.append(sid)
    except Exception:
        pass

    print(f"__REPORT__exists={int(exists)}")
    print(f"__REPORT__risky={int(risky)}")
    print(f"__REPORT__max_scale={max_scale:g}")
    print(f"__REPORT__sessions={','.join(remote_ids)}")
    print(f"__REPORT__detail={' | '.join(detail_parts) if detail_parts else 'ok'}")
    PY
    """

    private static let recoverScript = """
    set -e
    MON="$HOME/.config/monitors.xml"
    BACKUP=""
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
    echo "__RECOVER__backup=${BACKUP:-none}"
    echo "__RECOVER__terminated=$TERMINATED"
    """

    private static func parseReport(_ stdout: String) -> RemoteDisplayReport {
        RemoteDisplayReport(
            monitorsFileExists: parseValue(stdout, key: "exists") == "1",
            riskyLayout: parseValue(stdout, key: "risky") == "1",
            maxMetaScale: Double(parseValue(stdout, key: "max_scale") ?? "1") ?? 1,
            remoteSessionIDs: parseValue(stdout, key: "sessions")?
                .split(separator: ",").map(String.init).filter { !$0.isEmpty } ?? [],
            detail: parseValue(stdout, key: "detail") ?? ""
        )
    }

    private static func parseValue(_ stdout: String, key: String, namespace: String = "REPORT") -> String? {
        let marker = "__\(namespace)__\(key)="
        guard let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix(marker) }) else {
            return nil
        }
        return String(line.dropFirst(marker.count))
    }
}
