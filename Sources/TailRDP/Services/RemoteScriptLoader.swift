import Foundation
import CryptoKit

/// Loads bundled remote scripts with SHA256 pinning.
enum RemoteScriptLoader {
    enum Script: String, CaseIterable {
        case terminateSessions = "terminate_sessions.sh"
        case recover = "recover.sh"
        case report = "report.py"
    }

    private static let expectedHashes: [Script: String] = [
        .terminateSessions: "6ad68a517df665d30b51464e971296214243226b16568c5ac2c3c9dedd07ec0f",
        .recover: "f750317530924db0b2590c5f9189388435a3cae829723fd78c010d3c903e084e",
        .report: "efd498428b39dcdcf691d6d5269c88c091f59a12c3674747f3f7bc72a24f7ae8",
    ]
    private static var cache: [Script: String] = [:]

    static func load(_ script: Script) -> String {
        if let cached = cache[script] { return cached }
        for source in [bundledContents, sourceTreeContents] {
            if let text = source(script), verify(text, script: script) {
                cache[script] = text
                return text
            }
        }
        AppLog.ssh.error("Remote script \(script.rawValue, privacy: .public) checksum mismatch — refusing to run")
        return ""
    }

    static func reportScript(sinceMinutes: Int?) -> String {
        let prefix = sinceMinutes.map { "SINCE_MINUTES=\($0) " } ?? ""
        return prefix + "python3 - <<'PY'\n" + load(.report) + "\nPY"
    }

    static func terminateSessionsScript(exceptSessionID: String? = nil) -> String {
        var script = load(.terminateSessions)
        if let except = exceptSessionID, !except.isEmpty {
            let escaped = except.replacingOccurrences(of: "'", with: "'\\''")
            script = "TAILRDP_EXCEPT_SESSION='\(escaped)'\n" + script
        }
        return script
    }

    static func recoverScript() -> String { load(.recover) }

    /// Confirms pinned hashes match on-disk script files (used by `--verify-session`).
    static func verifyPinnedHashes() -> [String] {
        var failures: [String] = []
        for script in Script.allCases {
            guard let text = sourceTreeContents(script) else {
                failures.append("\(script.rawValue): missing from source tree")
                continue
            }
            let hash = sha256(text)
            if hash != expectedHashes[script] {
                failures.append("\(script.rawValue): expected \(expectedHashes[script] ?? "?"), got \(hash)")
            }
        }
        return failures
    }

    private static func bundledContents(_ script: Script) -> String? {
        let bundles: [(Bundle, String?)] = [
            (Bundle.module, nil),
            (Bundle.main, "RemoteScripts"),
            (Bundle.main, nil),
        ]
        for (bundle, subdir) in bundles {
            if let url = bundle.url(forResource: script.rawValue, withExtension: nil, subdirectory: subdir),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    private static func sourceTreeContents(_ script: Script) -> String? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("RemoteScripts/\(script.rawValue)")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func verify(_ contents: String, script: Script) -> Bool {
        sha256(contents) == expectedHashes[script]
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
