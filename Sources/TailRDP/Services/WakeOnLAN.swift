import Foundation

/// Wake a host that is asleep or powered off, with a magic packet on the local network.
///
/// Only works when this Mac shares a LAN with the target: the packet goes out as a
/// subnet broadcast and routers do not forward it. The MAC comes from this Mac's ARP
/// table, read while the host was last up — so a host TailRDP has never seen online on
/// this network cannot be woken, and neither can one reachable only through DERP.
enum WakeOnLAN {
    /// 9 is the conventional WoL port; 7 is there for NICs that only listen on echo.
    static let ports: [UInt16] = [9, 7]

    // MARK: - Packet

    /// 6 x 0xFF, then the target MAC repeated 16 times.
    static func magicPacket(mac: String) -> Data? {
        guard let addr = macBytes(mac) else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(addr) }
        return packet
    }

    /// macOS `arp` prints octets unpadded ("da:8:94:66:ef:5a"), so accept 1 or 2 digits.
    static func macBytes(_ mac: String) -> Data? {
        let parts = mac.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var out = Data(capacity: 6)
        for part in parts {
            guard part.count <= 2, let byte = UInt8(part, radix: 16) else { return nil }
            out.append(byte)
        }
        return out
    }

    /// Canonical lowercase colon form, or nil when the input is not a MAC.
    static func normalized(mac: String) -> String? {
        macBytes(mac).map { bytes in
            bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }

    /// ponytail: assumes a /24. Upgrade path: read the real prefix for the matching
    /// local interface via getifaddrs and compute the true broadcast address.
    static func broadcastAddress(forLAN ip: String) -> String? {
        let octets = ip.split(separator: ".")
        guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2]).255"
    }

    /// RFC1918 only — a peer endpoint outside these is a WAN address, not a LAN one,
    /// and broadcasting to its subnet would target a stranger's network.
    static func isPrivateIPv4(_ ip: String) -> Bool {
        let o = ip.split(separator: ".").compactMap { UInt8($0) }
        guard o.count == 4 else { return false }
        switch (o[0], o[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Host part of a `tailscale status` CurAddr ("192.168.1.73:41641"), when it is a LAN address.
    static func lanAddress(fromCurAddr curAddr: String) -> String? {
        guard let host = curAddr.split(separator: ":").first.map(String.init),
              isPrivateIPv4(host) else { return nil }
        return host
    }

    // MARK: - Send

    /// Broadcast the magic packet on every port in `ports`. Returns false only when
    /// nothing could be sent at all.
    @discardableResult
    static func send(mac: String, broadcast: String) -> Bool {
        guard let packet = magicPacket(mac: mac) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            return false
        }

        var sentAny = false
        for port in ports {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, broadcast, &addr.sin_addr) == 1 else { continue }

            let sent = packet.withUnsafeBytes { buf -> Int in
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent > 0 { sentAny = true }
        }
        return sentAny
    }

    /// Wake a saved host. Nil MAC or LAN address means we never saw it up on this network.
    @discardableResult
    static func wake(profile: HostProfile) -> Bool {
        guard let mac = profile.wakeMAC,
              let lan = profile.wakeLANAddress,
              let broadcast = broadcastAddress(forLAN: lan) else { return false }
        let ok = send(mac: mac, broadcast: broadcast)
        AppLog.session.info(
            "WoL \(ok ? "sent" : "failed") for \(profile.id, privacy: .public) via \(broadcast, privacy: .public)"
        )
        return ok
    }

    // MARK: - ARP

    /// This Mac's ARP table as LAN IP -> normalized MAC. Blocking: call off the main thread.
    static func arpTable() -> [String: String] {
        let res = ProcessRunner.run("/usr/sbin/arp", ["-an"])
        var table: [String: String] = [:]
        for line in res.stdout.split(separator: "\n") {
            // "? (192.168.1.73) at 74:56:3c:68:55:b4 on en0 ifscope [ethernet]"
            guard let ipRange = line.range(of: "\\([0-9.]+\\)", options: .regularExpression),
                  let macRange = line.range(of: "([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}", options: .regularExpression),
                  let mac = normalized(mac: String(line[macRange])) else { continue }
            table[String(line[ipRange].dropFirst().dropLast())] = mac
        }
        return table
    }

    /// This Mac's default gateway. Blocking: call off the main thread.
    static func defaultGatewayIPv4() -> String? {
        gatewayIPv4(fromRouteOutput: ProcessRunner.run("/sbin/route", ["-n", "get", "default"]).stdout)
    }

    /// "    gateway: 192.168.1.1" out of `route -n get default`.
    static func gatewayIPv4(fromRouteOutput out: String) -> String? {
        guard let range = out.range(of: "gateway: *[0-9.]+", options: .regularExpression),
              let ip = out[range].split(separator: " ").last.map(String.init),
              ip.split(separator: ".").count == 4 else { return nil }
        return ip
    }

    // MARK: - Wait

    /// Poll `tailscale status` until the peer reports online, or the timeout expires.
    static func waitForPeerOnline(
        peerID: String,
        timeout: TimeInterval,
        poll: Duration = .seconds(2)
    ) async -> Bool {
        let override = UserDefaults.standard.string(forKey: AppSettingsKey.tailscaleBinaryPath)
        guard let bin = DependencyChecker.tailscale(override: override).path else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: poll)
            if Task.isCancelled { return false }
            let online = await Task.detached(priority: .userInitiated) { () -> Bool in
                let res = ProcessRunner.run(bin, ["status", "--json"])
                guard let parsed = TailscaleService.parse(res.stdout) else { return false }
                return parsed.peers.first { $0.id == peerID }?.online ?? false
            }.value
            if online { return true }
        }
        return false
    }
}
