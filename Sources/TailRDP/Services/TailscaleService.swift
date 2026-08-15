import Foundation
import Combine

/// Discovers tailnet machines via `tailscale status --json`.
@MainActor
final class TailscaleService: ObservableObject {
    @Published var peers: [TailscalePeer] = []
    @Published var selfPeer: TailscalePeer?
    @Published var lastError: String?
    @Published var isRefreshing = false

    private var refreshGeneration: UInt64 = 0
    private var autoRefreshTask: Task<Void, Never>?
    private static let autoRefreshInterval: Duration = .seconds(15 * 60)

    init() {
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.autoRefreshInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    /// Auto-detected path (first existing candidate), for display in Settings.
    var detectedPath: String? {
        DependencyChecker.tailscaleCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Effective path: a non-empty, executable override from Settings wins;
    /// otherwise the auto-detected candidate.
    var binaryPath: String? {
        if let override = Self.validBinaryOverride() { return override }
        return detectedPath
    }

    /// Ignore/clear stale Settings overrides that are not executable paths.
    private static func validBinaryOverride() -> String? {
        let override = UserDefaults.standard.string(forKey: AppSettingsKey.tailscaleBinaryPath) ?? ""
        guard !override.isEmpty else { return nil }
        guard FileManager.default.isExecutableFile(atPath: override) else {
            UserDefaults.standard.removeObject(forKey: AppSettingsKey.tailscaleBinaryPath)
            return nil
        }
        return override
    }

    func refresh() {
        guard let bin = binaryPath else {
            lastError = "Tailscale CLI not found"
            return
        }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        Task.detached(priority: .userInitiated) {
            let res = ProcessRunner.run(bin, ["status", "--json"])
            var parsed = Self.parse(res.stdout)
            if parsed != nil {
                parsed!.peers = Self.withLearnedMACs(parsed!.peers)
                AppLog.tailscale.info("Refreshed \(parsed!.peers.count) peer(s)")
            } else {
                AppLog.tailscale.error("tailscale status failed: \(AppLog.stderrTail(res.stderr), privacy: .public)")
            }
            await self.apply(
                parsed: parsed,
                stdout: res.stdout,
                stderr: res.stderr,
                generation: generation
            )
        }
    }

    private func apply(
        parsed: (backendState: String, selfPeer: TailscalePeer?, peers: [TailscalePeer])?,
        stdout: String,
        stderr: String,
        generation: UInt64
    ) {
        guard generation == refreshGeneration else { return }
        isRefreshing = false
        if let parsed {
            if parsed.selfPeer != selfPeer || parsed.peers != peers {
                selfPeer = parsed.selfPeer
                peers = parsed.peers
            }
            lastError = Self.backendStateError(parsed.backendState)
        } else {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = !err.isEmpty ? err : out
            lastError = msg.isEmpty ? "Could not read tailscale status" : msg
        }
    }

    /// Human-readable reason the tunnel is down, or nil when the backend is up.
    /// A stale netmap parses fine while the tunnel is down, so this is the only
    /// signal that peers are unreachable.
    nonisolated static func backendStateError(_ state: String) -> String? {
        switch state {
        case "Running": return nil
        case "Stopped": return "Tailscale is disconnected — open Tailscale and click Connect"
        case "NeedsLogin": return "Tailscale is signed out — sign in from the Tailscale menu"
        case "NeedsMachineAuth": return "This machine needs approval in the Tailscale admin console"
        case "Starting": return "Tailscale is starting…"
        default: return "Tailscale is not running (\(state))"
        }
    }

    /// Fill in the MAC for every peer we can currently see on this LAN, so a host that
    /// later goes to sleep can still be woken. One `arp` pass for all peers, skipped
    /// entirely when nothing is reachable directly. Blocking: call off the main thread.
    ///
    /// CurAddr is the endpoint we send to, not proof of the peer's own address: with both
    /// machines behind one NAT, tailscale can report the router's hairpin endpoint, whose
    /// MAC would swallow every magic packet. A learned pair is never cleared, so refusing
    /// to learn beats learning a lie.
    nonisolated static func withLearnedMACs(_ peers: [TailscalePeer]) -> [TailscalePeer] {
        guard peers.contains(where: { $0.lanAddress != nil }) else { return peers }
        guard let gateway = WakeOnLAN.defaultGatewayIPv4() else {
            AppLog.tailscale.error("No default gateway — skipping wake MAC learning")
            return peers
        }
        let table = WakeOnLAN.arpTable()
        return peers.map { peer in
            guard let lan = peer.lanAddress, lan != gateway else {
                var cleared = peer
                cleared.lanAddress = nil
                return cleared
            }
            guard let mac = table[lan] else { return peer }
            var updated = peer
            updated.wakeMAC = mac
            return updated
        }
    }

    nonisolated static func parse(
        _ json: String
    ) -> (backendState: String, selfPeer: TailscalePeer?, peers: [TailscalePeer])? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let backendState = obj["BackendState"] as? String ?? "NoState"
        let tunnelUp = backendState == "Running"

        func makePeer(_ d: [String: Any], isSelf: Bool) -> TailscalePeer? {
            guard let host = d["HostName"] as? String else { return nil }
            let ips = d["TailscaleIPs"] as? [String] ?? []
            let ipv4 = ips.first { !$0.contains(":") } ?? ips.first ?? ""
            return TailscalePeer(
                id: host.lowercased(),
                hostName: host,
                dnsName: d["DNSName"] as? String ?? "",
                os: (d["OS"] as? String ?? "").lowercased(),
                ipv4: ipv4,
                online: tunnelUp && (d["Online"] as? Bool ?? false),
                isSelf: isSelf,
                lanAddress: (d["CurAddr"] as? String).flatMap { WakeOnLAN.lanAddress(fromCurAddr: $0) }
            )
        }

        let selfPeer = (obj["Self"] as? [String: Any]).flatMap { makePeer($0, isSelf: true) }
        var peers: [TailscalePeer] = []
        if let peerMap = obj["Peer"] as? [String: Any] {
            for (_, value) in peerMap {
                if let d = value as? [String: Any], let p = makePeer(d, isSelf: false) { peers.append(p) }
            }
        }
        peers.sort {
            ($0.online ? 0 : 1, $0.hostName.lowercased()) < ($1.online ? 0 : 1, $1.hostName.lowercased())
        }
        return (backendState, selfPeer, peers)
    }
}
