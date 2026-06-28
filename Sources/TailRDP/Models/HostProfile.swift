import Foundation

/// A saved, editable connection profile. The password is NOT stored here —
/// it lives in the macOS Keychain (service `app.tailrdp`), keyed by `id`.
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
    var lastWorking: LastWorkingSnapshot?
    var sessionHealth: SessionHealth?
    /// Pause/crash banner — persists when switching hosts; cleared on logout or dismiss.
    var stickyBanner: HostStatusBanner?

    var health: SessionHealth {
        get { sessionHealth ?? SessionHealth() }
        set { sessionHealth = newValue }
    }

    /// Settings used for the next Connect — last known good, or current form values.
    var connectSettings: RDPSettings {
        lastWorking?.settings ?? settings
    }

    func profileForConnect() -> HostProfile {
        var p = self
        p.settings = connectSettings
        return p
    }

    enum CodingKeys: String, CodingKey {
        case id, hostName, displayName, address, os, online
        case rdpUsername, sshUsername, rdpPort, settings, lastRemoteDir
        case lastWorking, sessionHealth, stickyBanner
    }

    init(
        id: String, hostName: String, displayName: String, address: String, os: String,
        online: Bool, rdpUsername: String, sshUsername: String, rdpPort: Int,
        settings: RDPSettings, lastRemoteDir: String,
        lastWorking: LastWorkingSnapshot? = nil, sessionHealth: SessionHealth? = nil,
        stickyBanner: HostStatusBanner? = nil
    ) {
        self.id = id
        self.hostName = hostName
        self.displayName = displayName
        self.address = address
        self.os = os
        self.online = online
        self.rdpUsername = rdpUsername
        self.sshUsername = sshUsername
        self.rdpPort = rdpPort
        self.settings = settings
        self.lastRemoteDir = lastRemoteDir
        self.lastWorking = lastWorking
        self.sessionHealth = sessionHealth
        self.stickyBanner = stickyBanner
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hostName = try c.decode(String.self, forKey: .hostName)
        displayName = try c.decode(String.self, forKey: .displayName)
        address = try c.decode(String.self, forKey: .address)
        os = try c.decode(String.self, forKey: .os)
        online = try c.decode(Bool.self, forKey: .online)
        rdpUsername = try c.decode(String.self, forKey: .rdpUsername)
        sshUsername = try c.decode(String.self, forKey: .sshUsername)
        rdpPort = try c.decode(Int.self, forKey: .rdpPort)
        settings = try c.decode(RDPSettings.self, forKey: .settings)
        lastRemoteDir = try c.decode(String.self, forKey: .lastRemoteDir)
        lastWorking = try c.decodeIfPresent(LastWorkingSnapshot.self, forKey: .lastWorking)
        sessionHealth = try c.decodeIfPresent(SessionHealth.self, forKey: .sessionHealth)
        stickyBanner = try c.decodeIfPresent(HostStatusBanner.self, forKey: .stickyBanner)
    }

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
