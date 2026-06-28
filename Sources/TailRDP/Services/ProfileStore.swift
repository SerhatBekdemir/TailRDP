import Foundation
import Combine

/// Persists host profiles to Application Support and merges live discovery.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [HostProfile] = []
    /// Short-lived green banner for clean disconnect — not sticky across host switches.
    @Published var ephemeralBanner: EphemeralBanner?

    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailRDP", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("profiles.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([HostProfile].self, from: data) else { return }
        profiles = list
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func profile(id: String) -> HostProfile? { profiles.first { $0.id == id } }

    func update(id: String, _ transform: (inout HostProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        transform(&profiles[i])
        save()
    }

    func applySessionOutcome(profileID: String, outcome: SessionEndOutcome) {
        update(id: profileID) { p in
            p.stickyBanner = HostStatusBanner.from(outcome)
        }
        switch outcome.kind {
        case .loggedOut:
            ephemeralBanner = EphemeralBanner(hostID: profileID, text: "Disconnected.")
        case .paused, .crashed:
            if ephemeralBanner?.hostID == profileID {
                ephemeralBanner = nil
            }
        }
    }

    func clearEphemeralBanner(hostID: String) {
        if ephemeralBanner?.hostID == hostID {
            ephemeralBanner = nil
        }
    }

    func clearStickyBanner(profileID: String) {
        update(id: profileID) { p in
            p.stickyBanner = nil
        }
    }

    func upsert(_ profile: HostProfile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
        } else {
            profiles.append(profile)
        }
        save()
    }

    func remove(id: String) {
        profiles.removeAll { $0.id == id }
        CredentialStore.shared.remove(for: id)
        save()
    }

    /// Update online/address/os for known hosts; create defaults for new RDP
    /// candidates; mark vanished hosts offline.
    func merge(peers: [TailscalePeer]) {
        guard !peers.isEmpty else { return }
        for peer in peers {
            if let i = profiles.firstIndex(where: { $0.id == peer.id }) {
                profiles[i].online = peer.online
                if !peer.ipv4.isEmpty { profiles[i].address = peer.ipv4 }
                profiles[i].os = peer.os
            } else if peer.isRDPCandidate {
                profiles.append(HostProfile.make(from: peer))
            }
        }
        let ids = Set(peers.map { $0.id })
        for i in profiles.indices where !ids.contains(profiles[i].id) {
            profiles[i].online = false
        }
        save()
    }
}
