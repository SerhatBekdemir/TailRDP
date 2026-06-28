import Foundation

public struct SessionEndClassification: Equatable {
    public let kind: SessionEndKind
    public let message: String
    public let errInfoCode: String?
}

/// Observed session-end inputs from production RDP runs — each must classify to `expectedKind`.
public struct SessionEndProductionRecord: Codable, Equatable, Sendable {
    public let name: String
    public let loggedOut: Bool
    public let stderr: String
    public let exitCode: Int32
    public let reason: String
    public let expectedKind: SessionEndKind
}

/// Pure classification of how an RDP client process ended — testable without SSH.
public enum SessionEndClassifier {
    /// Curated production observations; keep in sync with `Tests/.../session-end-production-records.json`.
    public static let productionRecords: [SessionEndProductionRecord] = [
        .init(name: "Mac window close (131) → paused", loggedOut: false, stderr: "", exitCode: 131, reason: "exit", expectedKind: .paused),
        .init(name: "Remote close screen → paused (ERRINFO_LOGOFF_BY_USER)", loggedOut: false, stderr: "ERRINFO_LOGOFF_BY_USER", exitCode: 0, reason: "exit", expectedKind: .paused),
        .init(name: "Another client took over → paused", loggedOut: false, stderr: "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION", exitCode: 0, reason: "exit", expectedKind: .paused),
        .init(name: "TailRDP Disconnect → loggedOut", loggedOut: true, stderr: "", exitCode: 131, reason: "exit", expectedKind: .loggedOut),
        .init(name: "Unexpected exit → crashed", loggedOut: false, stderr: "connection reset", exitCode: 42, reason: "exit", expectedKind: .crashed),
        .init(name: "Auth failure (24) empty stderr → crashed", loggedOut: false, stderr: "", exitCode: 24, reason: "exit", expectedKind: .crashed),
        .init(name: "AUTHENTICATION_FAILED in stderr → crashed", loggedOut: false, stderr: "AUTHENTICATION_FAILED", exitCode: 1, reason: "exit", expectedKind: .crashed),
        .init(name: "Passphrase prompt in stderr → crashed", loggedOut: false, stderr: "Enter passphrase for key", exitCode: 1, reason: "exit", expectedKind: .crashed),
        .init(name: "Signal without window-close code → crashed", loggedOut: false, stderr: "", exitCode: 0, reason: "signal", expectedKind: .crashed),
        .init(name: "SIGINT window close (130) → paused", loggedOut: false, stderr: "", exitCode: 130, reason: "signal", expectedKind: .paused),
        .init(name: "Clean exit zero → paused", loggedOut: false, stderr: "", exitCode: 0, reason: "exit", expectedKind: .paused),
        .init(name: "Server shutdown ERRINFO → crashed", loggedOut: false, stderr: "ERRINFO_SERVER_SHUTDOWN", exitCode: 0, reason: "exit", expectedKind: .crashed),
    ]

    public static func classify(
        loggedOut: Bool,
        stderr: String,
        exitCode: Int32,
        reason: String
    ) -> SessionEndClassification {
        if loggedOut {
            return SessionEndClassification(kind: .loggedOut, message: "Disconnected.", errInfoCode: nil)
        }
        if let errInfo = firstMatch(in: stderr, pattern: #"ERRINFO_[A-Z0-9_]+"#) {
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
            return SessionEndClassification(
                kind: .crashed,
                message: rdpErrorLabel(errInfo),
                errInfoCode: errInfo
            )
        }
        if !isKnownFailureExit(exitCode: exitCode, stderr: stderr),
           isClientWindowClosed(exitCode: exitCode, reason: reason, stderr: stderr) {
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
            let message: String
            if exitCode == 24 || isKnownFailureExit(exitCode: exitCode, stderr: stderr) {
                message = "Sign-in failed."
            } else {
                message = "Connection ended unexpectedly (code \(exitCode))."
            }
            return SessionEndClassification(
                kind: .crashed,
                message: message,
                errInfoCode: nil
            )
        }
        return SessionEndClassification(
            kind: .paused,
            message: "Session paused. Connect again to resume.",
            errInfoCode: nil
        )
    }

    public static func isClientWindowClosed(exitCode: Int32, reason: String, stderr: String) -> Bool {
        let windowCloseCodes: Set<Int32> = [130, 131, 143, 2, 3, 15]
        return windowCloseCodes.contains(exitCode)
    }

    /// Run every production record through `classify`. Returns failure count.
    @discardableResult
    public static func verifyProductionRecords() -> Int {
        var failures = 0
        for record in productionRecords {
            let kind = classify(
                loggedOut: record.loggedOut,
                stderr: record.stderr,
                exitCode: record.exitCode,
                reason: record.reason
            ).kind
            if kind == record.expectedKind {
                print("OK  \(record.name)")
            } else {
                print("FAIL \(record.name) (got \(kind), expected \(record.expectedKind))")
                failures += 1
            }
        }
        return failures
    }

    /// Built-in checks for pause / logout / crash classification. Returns failure count.
    @discardableResult
    public static func runBuiltInChecks() -> Int {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("OK  \(name)") }
            else { print("FAIL \(name)"); failures += 1 }
        }

        failures += verifyProductionRecords()
        check(HostStatusBanner.from(SessionEndOutcome(message: "paused", kind: .paused, actionLabel: "Resume")) != nil,
              "Paused outcome → sticky banner")
        check(HostStatusBanner.from(SessionEndOutcome(message: "lost", kind: .crashed, actionLabel: "Reconnect"))?.style == .error,
              "Crash outcome → error sticky")
        check(HostStatusBanner.from(SessionEndOutcome(message: "bye", kind: .loggedOut)) == nil,
              "Logout outcome → no sticky")
        check(RemoteDisplayRecovery.chooseRecovery(errInfo: "ERRINFO_LOGOFF_BY_USER", report: nil, failureCount: 9) == .none,
              "No recovery on LOGOFF_BY_USER")
        check(RemoteDisplayRecovery.looksLikeRecentCrash(RemoteSessionReport(
            layoutSummary: "", remoteSessionIDs: [], recentErrors: ["SEGV in gnome-shell"]
        )), "Journal SEGV → crash signal")
        check(HostStatusBanner.from(SessionEndOutcome(
            message: "x", kind: .paused, sshUnverified: true
        ))?.text.contains("verify") == true, "SSH unknown → unverified banner")
        let scriptFailures = RemoteScriptLoader.verifyPinnedHashes()
        if scriptFailures.isEmpty {
            print("OK  Remote script SHA256 pins")
        } else {
            for failure in scriptFailures {
                print("FAIL \(failure)")
                failures += 1
            }
        }

        if failures == 0 { print("All session logic checks passed.") }
        else { print("\(failures) check(s) failed.") }
        return failures
    }

    /// Non-zero exits that indicate failure, not a paused window close.
    private static func isKnownFailureExit(exitCode: Int32, stderr: String) -> Bool {
        if exitCode == 24 { return true }
        let lower = stderr.lowercased()
        if lower.contains("authentication_failed") || lower.contains("passphrase") { return true }
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
