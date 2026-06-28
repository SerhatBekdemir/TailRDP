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
}
