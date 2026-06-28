import Foundation
import Combine

/// Persists host profiles to Application Support and merges live discovery.
@MainActor
final class ProfileStore: ObservableObject {
    @Published var profiles: [HostProfile] = []
    /// Per-host flash banners (connect ack, disconnect) — survive host switches; not saved to disk.
    @Published private(set) var flashBanners: [String: HostFlashBanner] = [:]

    private var flashExpiryTasks: [String: Task<Void, Never>] = [:]
    private static let flashAutoDismissSeconds: UInt64 = 5

    private let url: URL

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TailRDP", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("profiles.json")
        load()
    }

    /// Isolated store for unit tests — does not load Application Support profiles.
    init(testProfilesURL: URL) {
        url = testProfilesURL
        try? FileManager.default.createDirectory(
            at: testProfilesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        profiles = []
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
            setFlashBanner(
                profileID: profileID,
                banner: HostFlashBanner(text: "Disconnected.", style: .success)
            )
        case .paused, .crashed:
            clearFlashBanner(profileID: profileID)
        }
    }

    func flashBanner(for profileID: String) -> HostFlashBanner? {
        flashBanners[profileID]
    }

    func setFlashBanner(profileID: String, banner: HostFlashBanner?) {
        flashExpiryTasks[profileID]?.cancel()
        flashExpiryTasks[profileID] = nil
        if let banner {
            flashBanners[profileID] = banner
            if banner.style == .success {
                flashExpiryTasks[profileID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(Self.flashAutoDismissSeconds))
                    guard let self, self.flashBanners[profileID] == banner else { return }
                    self.clearFlashBanner(profileID: profileID)
                }
            }
        } else {
            flashBanners.removeValue(forKey: profileID)
        }
    }

    func clearFlashBanner(profileID: String) {
        flashExpiryTasks[profileID]?.cancel()
        flashExpiryTasks[profileID] = nil
        flashBanners.removeValue(forKey: profileID)
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

    /// Add a manually entered host; returns nil on success or an error message.
    func addManualHost(
        displayName: String,
        address: String,
        os: String = "linux",
        rdpPort: Int = 3389
    ) -> String? {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "Display name is required." }
        guard !trimmedAddr.isEmpty else { return "Address is required." }
        let id = trimmedName.lowercased()
        if profiles.contains(where: { $0.id == id }) {
            return "A host named \"\(trimmedName)\" already exists."
        }
        let user = UserDefaults.standard.defaultUsername
        let profile = HostProfile(
            id: id,
            hostName: trimmedName,
            displayName: trimmedName,
            address: trimmedAddr,
            os: os,
            online: false,
            rdpUsername: user,
            sshUsername: user,
            rdpPort: rdpPort,
            settings: .default,
            lastRemoteDir: ""
        )
        profiles.append(profile)
        save()
        return nil
    }

    var visibleProfiles: [HostProfile] {
        let showOffline = UserDefaults.standard.bool(forKey: AppSettingsKey.showOffline)
        if showOffline { return profiles }
        return profiles.filter(\.online)
    }

    /// Update online/address/os for known hosts; create defaults for new RDP
    /// candidates; mark vanished hosts offline.
    func merge(peers: [TailscalePeer]) {
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

    /// Export profiles as JSON (passwords stay in Keychain — re-enter after import).
    func exportData() throws -> Data {
        let bundle = ProfileExportBundle(profiles: profiles)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(bundle)
    }

    /// Import profiles from an export bundle. Merges by id by default.
    func importData(_ data: Data, merge: Bool = true) throws -> ProfileImportResult {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let bundle = try dec.decode(ProfileExportBundle.self, from: data)
        guard bundle.version <= ProfileExportBundle.currentVersion else {
            throw ProfileImportError.unsupportedVersion(bundle.version)
        }
        var imported = 0
        var skipped = 0
        var needsPassword: [String] = []
        for profile in bundle.profiles {
            if merge, profiles.contains(where: { $0.id == profile.id }) {
                if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
                    var merged = profile
                    merged.online = profiles[i].online
                    if profiles[i].address.isEmpty == false, profile.address.isEmpty {
                        merged.address = profiles[i].address
                    }
                    profiles[i] = merged
                    imported += 1
                }
            } else if profiles.contains(where: { $0.id == profile.id }) {
                skipped += 1
            } else {
                profiles.append(profile)
                imported += 1
            }
            if !CredentialStore.shared.hasPassword(for: profile.id) {
                needsPassword.append(profile.displayName)
            }
        }
        save()
        return ProfileImportResult(imported: imported, skipped: skipped, needsPassword: needsPassword)
    }
}
