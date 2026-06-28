import Foundation
import os

/// Structured logging for field debugging — filter in Console.app by subsystem `app.tailrdp`.
enum AppLog {
    private static let subsystem = "app.tailrdp"

    static let tailscale = Logger(subsystem: subsystem, category: "tailscale")
    static let rdp = Logger(subsystem: subsystem, category: "rdp")
    static let ssh = Logger(subsystem: subsystem, category: "ssh")
    static let session = Logger(subsystem: subsystem, category: "session")

    /// Redact password-like substrings before logging FreeRDP argv.
    static func redactedArgv(_ args: [String]) -> String {
        args.map { arg in
            if arg.hasPrefix("/p:") { return "/p:(redacted)" }
            return arg
        }.joined(separator: " ")
    }

    /// Keep stderr tails bounded for log storage.
    static func stderrTail(_ text: String, maxBytes: Int = 2048) -> String {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        let suffix = data.suffix(maxBytes)
        return String(decoding: suffix, as: UTF8.self)
    }
}
