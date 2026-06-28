import XCTest
@testable import TailRDP

final class SessionEndClassifierTests: XCTestCase {
    func testDisconnectIsLoggedOut() {
        let end = SessionEndClassifier.classify(loggedOut: true, stderr: "", exitCode: 0, reason: "exit")
        XCTAssertEqual(end.kind, .loggedOut)
    }

    func testWindowCloseIsPaused() {
        let end = SessionEndClassifier.classify(loggedOut: false, stderr: "", exitCode: 131, reason: "exit")
        XCTAssertEqual(end.kind, .paused)
    }

    func testSignalIsCrashed() {
        let end = SessionEndClassifier.classify(loggedOut: false, stderr: "", exitCode: 0, reason: "signal")
        XCTAssertEqual(end.kind, .crashed)
    }

    func testLogoffByUserIsPaused() {
        let end = SessionEndClassifier.classify(
            loggedOut: false, stderr: "ERRINFO_LOGOFF_BY_USER", exitCode: 0, reason: "exit"
        )
        XCTAssertEqual(end.kind, .paused)
    }
}

final class DiscoveryTests: XCTestCase {
    func testAllPeersExceptSelfAreCandidates() {
        let linux = TailscalePeer(
            id: "box", hostName: "box", dnsName: "box.ts.net", os: "linux",
            ipv4: "100.1.1.1", online: true, isSelf: false
        )
        let mac = TailscalePeer(
            id: "mac", hostName: "mac", dnsName: "mac.ts.net", os: "macOS",
            ipv4: "100.1.1.2", online: true, isSelf: false
        )
        let selfPeer = TailscalePeer(
            id: "me", hostName: "me", dnsName: "me.ts.net", os: "macOS",
            ipv4: "100.1.1.3", online: true, isSelf: true
        )
        XCTAssertTrue(linux.isRDPCandidate)
        XCTAssertTrue(mac.isRDPCandidate)
        XCTAssertFalse(selfPeer.isRDPCandidate)
    }
}

final class RecoveryTests: XCTestCase {
    func testBenignDisconnectSkipsRecovery() {
        let preset = RemoteDisplayRecovery.chooseRecovery(
            errInfo: "ERRINFO_LOGOFF_BY_USER", report: nil, failureCount: 5
        )
        XCTAssertEqual(preset, .none)
    }

    func testSegvTriggersReset() {
        let report = RemoteSessionReport(
            layoutSummary: "", remoteSessionIDs: [], recentErrors: ["SEGV in gnome-shell"]
        )
        XCTAssertTrue(RemoteDisplayRecovery.looksLikeRecentCrash(report))
        let preset = RemoteDisplayRecovery.chooseRecovery(errInfo: nil, report: report, failureCount: 1)
        XCTAssertEqual(preset, .resetRemoteDesktop)
    }

    func testMultipleSessionsTriggersEndStuck() {
        let report = RemoteSessionReport(
            layoutSummary: "", remoteSessionIDs: ["3", "5"], recentErrors: []
        )
        let preset = RemoteDisplayRecovery.chooseRecovery(errInfo: nil, report: report, failureCount: 0)
        XCTAssertEqual(preset, .endStuckSessions)
    }

    func testFailureCountSafeFallback() {
        let preset = RemoteDisplayRecovery.chooseRecovery(errInfo: "ERRINFO_UNKNOWN", report: nil, failureCount: 2)
        XCTAssertEqual(preset, .useSafeClientSettings)
    }
}

final class RemoteScriptLoaderTests: XCTestCase {
    func testPinnedHashesMatchSourceTree() {
        XCTAssertTrue(RemoteScriptLoader.verifyPinnedHashes().isEmpty)
    }
}

final class RDPLauncherArgumentTests: XCTestCase {
    @MainActor
    func testLinuxSkipsAutoReconnect() {
        let launcher = RDPLauncher()
        var profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: { var s = RDPSettings(); s.autoReconnect = true; return s }(),
            lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, includeStdin: false)
        XCTAssertFalse(args.contains("+auto-reconnect"))
    }

    @MainActor
    func testStdinFlagWhenPasswordExpected() {
        let launcher = RDPLauncher()
        let profile = HostProfile(
            id: "win", hostName: "win", displayName: "win", address: "100.64.0.2", os: "windows",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, includeStdin: true)
        XCTAssertTrue(args.contains("/from-stdin:force"))
    }
}

final class SessionHealthTests: XCTestCase {
    func testAdaptiveDelayBounds() {
        var h = SessionHealth()
        XCTAssertEqual(h.linuxResumeDelayMs, SessionHealth.defaultLinuxResumeDelayMs)
        h.linuxResumeDelayMs = max(SessionHealth.minLinuxResumeDelayMs, h.linuxResumeDelayMs - 500)
        XCTAssertEqual(h.linuxResumeDelayMs, 2500)
        h.linuxResumeDelayMs = min(SessionHealth.maxLinuxResumeDelayMs, h.linuxResumeDelayMs + 1500)
        XCTAssertEqual(h.linuxResumeDelayMs, 4000)
    }
}

final class ProfileExportTests: XCTestCase {
    func testExportImportRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPExport-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let profile = HostProfile(
            id: "dev", hostName: "dev", displayName: "Dev", address: "100.64.0.3", os: "linux",
            online: false, rdpUsername: "alice", sshUsername: "alice", rdpPort: 3389,
            settings: .default, lastRemoteDir: "/home/alice"
        )
        store.profiles = [profile]
        let data = try store.exportData()
        let store2 = ProfileStore(testProfilesURL: url.deletingLastPathComponent().appendingPathComponent("import.json"))
        let result = try store2.importData(data)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(store2.profiles.first?.rdpUsername, "alice")
        XCTAssertTrue(result.needsPassword.contains("Dev"))
    }
}

@MainActor
final class ProfileStoreMergeTests: XCTestCase {
    func testMergeAddsPeersAndMarksVanishedOffline() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let peer = TailscalePeer(
            id: "devbox", hostName: "devbox", dnsName: "devbox.ts.net", os: "linux",
            ipv4: "100.64.0.1", online: true, isSelf: false
        )
        store.merge(peers: [peer])
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertTrue(store.profiles[0].online)
        XCTAssertEqual(store.profiles[0].address, "100.64.0.1")

        store.merge(peers: [])
        XCTAssertFalse(store.profiles[0].online)
    }

    func testMergeSkipsSelfPeer() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let selfPeer = TailscalePeer(
            id: "me", hostName: "me", dnsName: "me.ts.net", os: "macOS",
            ipv4: "100.64.0.2", online: true, isSelf: true
        )
        store.merge(peers: [selfPeer])
        XCTAssertTrue(store.profiles.isEmpty)
    }
}
