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

    /// RDP only makes sense for machines that can run a remote-desktop server.
    var isRDPCandidate: Bool { os == "linux" || os == "windows" }
}
