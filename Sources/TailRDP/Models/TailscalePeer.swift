import Foundation

/// A machine on the tailnet, parsed from `tailscale status --json`.
struct TailscalePeer: Identifiable, Equatable {
    let id: String          // stable key = lowercased hostname
    let hostName: String
    let dnsName: String
    let os: String          // "linux", "windows", "macOS", "android", ...
    let ipv4: String
    let online: Bool
    let isSelf: Bool

    /// All tailnet peers except this Mac appear in the sidebar; user configures RDP per host.
    var isRDPCandidate: Bool { !isSelf }
}
