import Foundation

/// A saved, editable connection profile. The password is NOT stored here —
/// it lives in the local 0600 CredentialStore, keyed by `id`.
struct HostProfile: Codable, Identifiable, Equatable {
    var id: String          // stable key = lowercased hostname (credential account too)
    var hostName: String
    var displayName: String
    var address: String     // tailscale IPv4 (or a manually entered host)
    var os: String
    var online: Bool        // refreshed from discovery; not authoritative at rest
    var rdpUsername: String
    var sshUsername: String
    var rdpPort: Int
    var settings: RDPSettings
    var lastRemoteDir: String

    static func make(from peer: TailscalePeer) -> HostProfile {
        let user = UserDefaults.standard.defaultUsername
        return HostProfile(
            id: peer.id,
            hostName: peer.hostName,
            displayName: peer.hostName,
            address: peer.ipv4,
            os: peer.os,
            online: peer.online,
            rdpUsername: user,
            sshUsername: user,
            rdpPort: 3389,
            settings: .default,
            lastRemoteDir: ""
        )
    }
}
