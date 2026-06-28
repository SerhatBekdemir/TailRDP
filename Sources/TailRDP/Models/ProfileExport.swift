import Foundation

struct ProfileExportBundle: Codable, Sendable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var profiles: [HostProfile]

    init(profiles: [HostProfile]) {
        version = Self.currentVersion
        exportedAt = Date()
        self.profiles = profiles
    }
}

struct ProfileImportResult: Sendable {
    var imported: Int
    var skipped: Int
    /// Display names of hosts that need a password re-entered in Connection settings.
    var needsPassword: [String]
}

enum ProfileImportError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v):
            return "Unsupported export version \(v)."
        }
    }
}
