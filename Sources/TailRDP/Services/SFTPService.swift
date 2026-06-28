import Foundation

struct RemoteEntry: Identifiable, Equatable {
    let name: String
    let isDirectory: Bool
    let size: Int64
    var id: String { name }
}

/// File transfer over SSH/SCP across the tailnet, using existing SSH keys.
/// All calls block — invoke from a background Task.
enum SFTPService {
    private static let ssh = "/usr/bin/ssh"
    private static let scp = "/usr/bin/scp"

    private static let commonOpts = [
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ConnectTimeout=10",
        "-o", "BatchMode=yes"
    ]

    static func target(_ p: HostProfile) -> String { "\(p.sshUsername)@\(p.address)" }

    /// Run a shell script on the remote host over SSH. Blocking — use from a Task.
    static func runScript(_ profile: HostProfile, script: String) -> ProcessResult {
        ProcessRunner.run(ssh, commonOpts + [target(profile), script])
    }

    /// Single-quote a path for safe interpolation into a remote shell command.
    private static func shq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func listRemote(_ profile: HostProfile, path: String) -> Result<[RemoteEntry], AppError> {
        let script = """
        cd \(shq(path)) 2>/dev/null || { echo "__ERR__cd"; exit 9; }
        for f in .* *; do
          [ -e "$f" ] || continue
          [ "$f" = "." ] && continue
          [ "$f" = ".." ] && continue
          if [ -d "$f" ]; then echo "d|$f|0"
          else echo "f|$f|$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)"
          fi
        done
        """
        let res = ProcessRunner.run(ssh, commonOpts + [target(profile), script])
        if res.stdout.contains("__ERR__cd") {
            return .fail("Cannot open \(path)")
        }
        if !res.ok && res.stdout.isEmpty {
            let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .fail(msg.isEmpty ? "ssh failed (exit \(res.exitCode))" : msg)
        }
        var entries: [RemoteEntry] = []
        for line in res.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            entries.append(RemoteEntry(name: String(parts[1]),
                                       isDirectory: parts[0] == "d",
                                       size: Int64(parts[2]) ?? 0))
        }
        entries.sort {
            ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased())
        }
        return .success(entries)
    }

    static func push(_ profile: HostProfile, localPaths: [String], remoteDir: String) -> Result<String, AppError> {
        guard !localPaths.isEmpty else { return .fail("No local items selected") }
        let args = commonOpts + ["-r"] + localPaths + ["\(target(profile)):\(remoteDir)"]
        let res = ProcessRunner.run(scp, args)
        return res.ok
            ? .success("Pushed \(localPaths.count) item(s) → \(remoteDir)")
            : .fail(res.stderr.isEmpty ? "scp failed (exit \(res.exitCode))" : res.stderr)
    }

    static func pull(_ profile: HostProfile, remotePaths: [String], localDir: String) -> Result<String, AppError> {
        guard !remotePaths.isEmpty else { return .fail("No remote items selected") }
        let sources = remotePaths.map { "\(target(profile)):\(shq($0))" }
        let args = commonOpts + ["-r"] + sources + [localDir]
        let res = ProcessRunner.run(scp, args)
        return res.ok
            ? .success("Pulled \(remotePaths.count) item(s) → \(localDir)")
            : .fail(res.stderr.isEmpty ? "scp failed (exit \(res.exitCode))" : res.stderr)
    }
}
