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
    /// LAN endpoint from CurAddr, when the peer is reachable directly on this network.
    /// Only set for RFC1918 addresses — it is what Wake-on-LAN broadcasts to.
    var lanAddress: String?
    /// Hardware address behind `lanAddress`, read from this Mac's ARP table.
    var wakeMAC: String?

    /// Desktop tailnet peers (linux / windows / macOS / other) — excludes phones, TVs, etc.
    var isRDPCandidate: Bool { HostOS.isTailscaleRDPCandidate(os: os, isSelf: isSelf) }
}
