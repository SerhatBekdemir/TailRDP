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

    private static let binaryCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale"
    ]

    /// Auto-detected path (first existing candidate), for display in Settings.
    var detectedPath: String? {
        Self.binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
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
            let parsed = Self.parse(res.stdout)
            if parsed != nil {
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
        parsed: (selfPeer: TailscalePeer?, peers: [TailscalePeer])?,
        stdout: String,
        stderr: String,
        generation: UInt64
    ) {
        guard generation == refreshGeneration else { return }
        isRefreshing = false
        if let parsed {
            selfPeer = parsed.selfPeer
            peers = parsed.peers
            lastError = nil
        } else {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = !err.isEmpty ? err : out
            lastError = msg.isEmpty ? "Could not read tailscale status" : msg
        }
    }

    nonisolated static func parse(_ json: String) -> (selfPeer: TailscalePeer?, peers: [TailscalePeer])? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

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
                online: d["Online"] as? Bool ?? false,
                isSelf: isSelf
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
        return (selfPeer, peers)
    }
}
