import Foundation

/// How an RDP session ended — drives banner style and whether recovery runs.
enum SessionEndKind: String, Codable, Equatable {
    /// Window closed or remote "close screen"; session still alive on host.
    case paused
    /// TailRDP Disconnect or remote Log out; session finished.
    case loggedOut
    /// Unexpected failure (crash, signal, non-recoverable error).
    case crashed
}

/// Sticky status shown when returning to a host (pause / crash — not clean disconnect).
struct HostStatusBanner: Codable, Equatable {
    enum Style: String, Codable {
        case paused
        case error
    }

    var text: String
    var detail: String?
    var style: Style
    var actionLabel: String?

    static func from(_ outcome: SessionEndOutcome) -> HostStatusBanner? {
        switch outcome.kind {
        case .loggedOut:
            return nil
        case .paused:
            return HostStatusBanner(
                text: outcome.message,
                detail: outcome.fixSummary,
                style: .paused,
                actionLabel: outcome.actionLabel
            )
        case .crashed:
            return HostStatusBanner(
                text: outcome.message,
                detail: outcome.fixSummary,
                style: .error,
                actionLabel: outcome.actionLabel
            )
        }
    }
}

/// UI + state result after a session ends.
struct SessionEndOutcome: Equatable {
    var message: String
    var kind: SessionEndKind
    var fixSummary: String?
    /// Button label when the user may connect again ("Resume" / "Reconnect").
    var actionLabel: String?

    var isError: Bool { kind == .crashed }
}

/// Snapshot of RDP settings that last produced a usable session.
struct LastWorkingSnapshot: Codable, Equatable {
    var settings: RDPSettings
    var savedAt: Date
}

/// Per-host connect reliability — drives crash recovery only.
struct SessionHealth: Codable, Equatable {
    var consecutiveFailures: Int = 0
    var lastFailureSummary: String?
    var usingSafeFallback: Bool = false
    var lastEndKind: SessionEndKind?
}

extension RDPSettings {
    /// Conservative client settings used after repeated connect failures.
    static var safeFallback: RDPSettings {
        var s = RDPSettings()
        s.width = 1920
        s.height = 1080
        s.bpp = 16
        s.codec = .avc420
        s.network = .lan
        s.dynamicResolution = false
        return s
    }

    var connectSummary: String {
        let res = dynamicResolution ? "dynamic" : "\(width)×\(height)"
        return "\(res), \(codec.rawValue), \(network.rawValue)"
    }
}
