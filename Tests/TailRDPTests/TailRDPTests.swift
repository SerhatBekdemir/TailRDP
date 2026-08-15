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

    func testAuthFailureNotPaused() {
        let end = SessionEndClassifier.classify(loggedOut: false, stderr: "", exitCode: 24, reason: "exit")
        XCTAssertEqual(end.kind, .crashed)
        XCTAssertTrue(end.message.contains("Sign-in"))
    }

    func testUnexpectedExitEmptyStderrIsCrashed() {
        let end = SessionEndClassifier.classify(loggedOut: false, stderr: "", exitCode: 42, reason: "exit")
        XCTAssertEqual(end.kind, .crashed)
    }

    func testProductionRecordsJSONMatchesBuiltInCorpus() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/session-end-production-records.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([SessionEndProductionRecord].self, from: data)
        XCTAssertEqual(decoded, SessionEndClassifier.productionRecords)
    }

    func testProductionRecordsClassifyCorrectly() {
        XCTAssertEqual(SessionEndClassifier.verifyProductionRecords(), 0)
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
        let android = TailscalePeer(
            id: "phone", hostName: "phone", dnsName: "phone.ts.net", os: "android",
            ipv4: "100.1.1.4", online: true, isSelf: false
        )
        let selfPeer = TailscalePeer(
            id: "me", hostName: "me", dnsName: "me.ts.net", os: "macOS",
            ipv4: "100.1.1.3", online: true, isSelf: true
        )
        XCTAssertTrue(linux.isRDPCandidate)
        XCTAssertTrue(mac.isRDPCandidate)
        XCTAssertFalse(android.isRDPCandidate)
        XCTAssertFalse(selfPeer.isRDPCandidate)
    }

    func testTailscaleMacOSNormalizesToCanonicalOS() {
        let peer = TailscalePeer(
            id: "mbp", hostName: "mbp", dnsName: "mbp.ts.net", os: "macos",
            ipv4: "100.1.1.5", online: true, isSelf: false
        )
        XCTAssertTrue(peer.isRDPCandidate)
        let profile = HostProfile.make(from: peer)
        XCTAssertEqual(profile.os, "macOS")
    }

    /// A stopped backend still returns a full stale netmap with Online:true peers.
    /// Those peers are unreachable — no tailnet route exists — so they must not
    /// render as online, and the state must surface as an error.
    func testStoppedBackendForcesPeersOfflineAndReportsError() {
        let json = """
        {"BackendState":"Stopped",
         "Self":{"HostName":"mbp","OS":"macOS","TailscaleIPs":["100.1.1.1"],"Online":true},
         "Peer":{"k":{"HostName":"box","OS":"linux","TailscaleIPs":["100.1.1.2"],"Online":true}}}
        """
        let parsed = TailscaleService.parse(json)
        XCTAssertEqual(parsed?.backendState, "Stopped")
        XCTAssertEqual(parsed?.peers.first?.online, false)
        XCTAssertEqual(parsed?.selfPeer?.online, false)
        XCTAssertNotNil(TailscaleService.backendStateError("Stopped"))
    }

    func testRunningBackendPreservesPeerOnlineFlags() {
        let json = """
        {"BackendState":"Running",
         "Peer":{"a":{"HostName":"up","OS":"linux","TailscaleIPs":["100.1.1.2"],"Online":true},
                 "b":{"HostName":"down","OS":"linux","TailscaleIPs":["100.1.1.3"],"Online":false}}}
        """
        let parsed = TailscaleService.parse(json)
        XCTAssertEqual(parsed?.peers.first(where: { $0.hostName == "up" })?.online, true)
        XCTAssertEqual(parsed?.peers.first(where: { $0.hostName == "down" })?.online, false)
        XCTAssertNil(TailscaleService.backendStateError("Running"))
    }
}

final class RecoveryTests: XCTestCase {
    /// A force-ended Linux session clears the paused banner and records .loggedOut, so
    /// the resume path no longer matches. It still must wait — gnome-remote-desktop is
    /// respawning the login screen, and a client that connects mid-respawn gets a
    /// handover redirect the greeter never accepts, leaving a black window.
    @MainActor
    func testLoggedOutLinuxHostWaitsForLoginScreen() {
        func profile(os: String, endKind: SessionEndKind?) -> HostProfile {
            var p = HostProfile(
                id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: os,
                online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
                settings: .default, lastRemoteDir: ""
            )
            p.sessionHealth = SessionHealth(lastEndKind: endKind)
            return p
        }

        // The regression: TailRDP just ended the session, so wait even though this is
        // not a resume and the recorded end kind is a plain logout.
        XCTAssertEqual(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .loggedOut),
                isLinuxResume: false,
                secondsSinceRemoteEnd: 0
            ),
            SessionHealth.linuxRestartSettleDelayMs
        )
        // Time already spent counts against the wait.
        XCTAssertEqual(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .loggedOut),
                isLinuxResume: false,
                secondsSinceRemoteEnd: 5
            ),
            SessionHealth.linuxRestartSettleDelayMs - 5000
        )
        // Waited it out already — no tax.
        XCTAssertNil(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .loggedOut),
                isLinuxResume: false,
                secondsSinceRemoteEnd: 600
            )
        )
        // A logout from an earlier app run has no timestamp, so nothing to wait for.
        XCTAssertNil(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .loggedOut),
                isLinuxResume: false,
                secondsSinceRemoteEnd: nil
            )
        )
        // Crash recovery ends sessions too, and it is not a resume either.
        XCTAssertEqual(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .crashed),
                isLinuxResume: false,
                secondsSinceRemoteEnd: 0
            ),
            SessionHealth.linuxRestartSettleDelayMs
        )
        // Paused resume with no teardown keeps the shorter socket-clear wait.
        XCTAssertEqual(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: .paused),
                isLinuxResume: true,
                secondsSinceRemoteEnd: nil
            ),
            SessionHealth.defaultLinuxResumeDelayMs
        )
        // A clean first connect waits for nothing.
        XCTAssertNil(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "linux", endKind: nil),
                isLinuxResume: false,
                secondsSinceRemoteEnd: nil
            )
        )
        // Windows hosts have no handover to race.
        XCTAssertNil(
            SessionCoordinator.linuxSettleDelayMs(
                profile: profile(os: "windows", endKind: .loggedOut),
                isLinuxResume: false,
                secondsSinceRemoteEnd: 0
            )
        )
    }

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

final class RDPSettingsTests: XCTestCase {
    func testDisplayModeFullscreenSetsRecommendedResolution() {
        var settings = RDPSettings()
        settings.width = 2560
        settings.height = 1440
        settings.apply(displayMode: .fullscreen)
        XCTAssertTrue(settings.fullscreen)
        XCTAssertFalse(settings.dynamicResolution)
        XCTAssertFalse(settings.multiMonitor)
        XCTAssertEqual(settings.width, 1920)
        XCTAssertEqual(settings.height, 1080)
    }

    func testDisplayModePreservesCustomFullscreenResolution() {
        var settings = RDPSettings()
        settings.width = 1920
        settings.height = 1080
        settings.apply(displayMode: .fullscreen)
        XCTAssertEqual(settings.width, 1920)
        XCTAssertEqual(settings.height, 1080)
    }

    func testConnectSummaryIncludesFullscreen() {
        var settings = RDPSettings()
        settings.apply(displayMode: .fullscreen)
        XCTAssertTrue(settings.connectSummary.contains("fullscreen 1920×1080"))
    }

    func testNormalizeClearsConflictingFlags() {
        var settings = RDPSettings()
        settings.fullscreen = true
        settings.dynamicResolution = true
        settings.multiMonitor = true
        settings.normalizeDisplayOptions()
        XCTAssertFalse(settings.dynamicResolution)
        XCTAssertFalse(settings.multiMonitor)
    }
}

final class RDPLauncherArgumentTests: XCTestCase {
    @MainActor
    func testLinuxSkipsAutoReconnect() {
        let launcher = RDPLauncher()
        let profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: { var s = RDPSettings(); s.autoReconnect = true; return s }(),
            lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, password: nil)
        XCTAssertFalse(args.contains("+auto-reconnect"))
    }

    @MainActor
    func testPasswordPassedInArgsWhenSet() {
        let launcher = RDPLauncher()
        let profile = HostProfile(
            id: "win", hostName: "win", displayName: "win", address: "100.64.0.2", os: "windows",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, password: "secret")
        XCTAssertTrue(args.contains("/p:secret"))
        // /from-stdin rejected: FreeRDP reads passphrases via tty ioctls — unusable from a GUI app.
        XCTAssertFalse(args.contains("/from-stdin"))
        XCTAssertTrue(args.contains("/sound"))
        XCTAssertFalse(args.contains("/sound:latency:200"))
        XCTAssertTrue(args.contains("/cert:tofu"))
        XCTAssertFalse(args.contains("/cert:ignore"))
    }

    @MainActor
    func testSoundArgumentFollowsAudioSetting() {
        let launcher = RDPLauncher()
        var settings = RDPSettings()
        settings.sound = false
        let profile = HostProfile(
            id: "win", hostName: "win", displayName: "win", address: "100.64.0.2", os: "windows",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: settings, lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, password: nil)
        XCTAssertFalse(args.contains("/sound:latency:200"))
        XCTAssertFalse(args.contains("/sound"))
    }

    @MainActor
    func testCustomCommandUsesEditedArgumentsAndInjectsSavedPassword() {
        let launcher = RDPLauncher()
        let profile = HostProfile(
            id: "win", hostName: "win", displayName: "win", address: "100.64.0.2", os: "windows",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: "",
            launchCommandOverride: "sdl-freerdp /v:custom.example:3390 /u:custom-user /sound"
        )
        let args = launcher.buildArguments(for: profile, password: "secret")
        XCTAssertFalse(args.contains("sdl-freerdp"))
        XCTAssertTrue(args.contains("/v:custom.example:3390"))
        XCTAssertTrue(args.contains("/u:custom-user"))
        XCTAssertTrue(args.contains("/sound"))
        XCTAssertTrue(args.contains("/p:secret"))
        XCTAssertNil(launcher.commandLineValidationError(for: profile))
    }

    func testCustomCommandSanitizesPasswordAndRejectsMalformedTarget() {
        let command = "sdl-freerdp /v:host:3389 /p:real-secret /sound"
        XCTAssertEqual(
            FreeRDPCommandLine.sanitized(command),
            "sdl-freerdp /v:host:3389 /p:•••••• /sound"
        )
        XCTAssertEqual(
            FreeRDPCommandLine.validationError(for: "sdl-freerdp /v:host:3389 /sound"),
            nil
        )
        XCTAssertNotNil(FreeRDPCommandLine.validationError(for: "sdl-freerdp /sound"))
        XCTAssertNotNil(FreeRDPCommandLine.validationError(for: "sdl-freerdp '/v:host:3389"))
    }

    @MainActor
    func testLinuxUsernameLowercasedInArgs() {
        let launcher = RDPLauncher()
        let profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "Aegis", sshUsername: "aegis", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, password: nil)
        XCTAssertTrue(args.contains("/u:aegis"))
    }

    @MainActor
    func testMacFullscreenUsesNativePresentation() {
        let launcher = RDPLauncher()
        var settings = RDPSettings()
        settings.fullscreen = true
        settings.width = 1920
        settings.height = 1080
        let profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: settings, lastRemoteDir: ""
        )
        let args = launcher.buildArguments(for: profile, password: nil)
        #if os(macOS)
        XCTAssertFalse(args.contains("/f"))
        XCTAssertFalse(args.contains("-decorations"))
        XCTAssertTrue(args.contains("/size:1920x1080"))
        XCTAssertTrue(args.contains("+dynamic-resolution"))
        XCTAssertTrue(args.contains("/floatbar:sticky:on,default:visible,show:fullscreen"))
        XCTAssertFalse(args.contains("/size:2560x1440"))
        #else
        XCTAssertTrue(args.contains("/f"))
        XCTAssertTrue(args.contains("/size:1920x1080"))
        #endif
    }
}

final class HostProfileCredentialTests: XCTestCase {
    func testNormalizeLinuxUsernames() {
        var profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: " Aegis ", sshUsername: " Aegis ", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        profile.normalizeCredentials()
        XCTAssertEqual(profile.rdpUsername, "aegis")
        XCTAssertEqual(profile.sshUsername, "aegis")
    }

    func testPausedTagFromHealthWhenBannerMissing() {
        var profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "a", sshUsername: "a", rdpPort: 3389,
            settings: .default, lastRemoteDir: "",
            sessionHealth: { var h = SessionHealth(); h.lastEndKind = .paused; return h }()
        )
        XCTAssertTrue(profile.hasPausedSession)
        profile.ensurePausedBanner()
        XCTAssertEqual(profile.stickyBanner?.style, .paused)
    }

    func testConnectSettingsPrecedence() {
        var profile = HostProfile(
            id: "box", hostName: "box", displayName: "box", address: "100.64.0.1", os: "linux",
            online: true, rdpUsername: "a", sshUsername: "a", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        XCTAssertEqual(profile.connectSettings, profile.settings)

        var lastGood = RDPSettings.default
        lastGood.width = 1600
        profile.lastWorking = LastWorkingSnapshot(settings: lastGood, savedAt: Date())
        XCTAssertEqual(profile.connectSettings, lastGood)

        profile.health.consecutiveFailures = 2
        XCTAssertTrue(profile.usesSafeFallback)
        XCTAssertEqual(profile.connectSettings, .safeFallback)
        XCTAssertEqual(profile.profileForConnect().settings, .safeFallback)
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

@MainActor
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

    func testCustomLaunchCommandRoundTripRedactsPassword() throws {
        let profile = HostProfile(
            id: "dev", hostName: "dev", displayName: "Dev", address: "100.64.0.3", os: "linux",
            online: false, rdpUsername: "alice", sshUsername: "alice", rdpPort: 3389,
            settings: .default, lastRemoteDir: "/home/alice",
            launchCommandOverride: "sdl-freerdp /v:dev:3389 /p:real-secret /sound"
        )
        let data = try JSONEncoder().encode(profile)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("real-secret"))
        XCTAssertTrue(encoded.contains(FreeRDPCommandLine.passwordPlaceholder))

        let decoded = try JSONDecoder().decode(HostProfile.self, from: data)
        XCTAssertEqual(
            decoded.launchCommandOverride,
            "sdl-freerdp /v:dev:3389 /p:\(FreeRDPCommandLine.passwordPlaceholder) /sound"
        )
    }

    func testImportMergePreservesLocalSessionState() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPExport-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let local = HostProfile(
            id: "dev", hostName: "dev", displayName: "Dev", address: "100.64.0.3", os: "linux",
            online: true, rdpUsername: "alice", sshUsername: "alice", rdpPort: 3389,
            settings: .default, lastRemoteDir: "/home/alice",
            sessionHealth: { var h = SessionHealth(); h.lastEndKind = .paused; return h }(),
            stickyBanner: HostStatusBanner(
                text: "Session paused.", detail: nil, style: .paused, actionLabel: "Resume"
            )
        )
        store.profiles = [local]
        var exported = local
        exported.online = false
        exported.stickyBanner = nil
        exported.sessionHealth = nil
        exported.settings.width = 2560
        let bundle = ProfileExportBundle(profiles: [exported])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(bundle)
        let result = try store.importData(data)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(store.profiles.first?.settings.width, 2560)
        XCTAssertEqual(store.profiles.first?.health.lastEndKind, .paused)
        XCTAssertEqual(store.profiles.first?.stickyBanner?.style, .paused)
        XCTAssertTrue(store.profiles.first?.online == true)
    }

    func testImportSkipsNonRDPCapableProfiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPExport-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let valid = HostProfile(
            id: "box", hostName: "box", displayName: "Box", address: "192.0.2.10", os: "linux",
            online: false, rdpUsername: "qa-user", sshUsername: "qa-user", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let invalid = HostProfile(
            id: "phone", hostName: "phone", displayName: "Phone", address: "192.0.2.11", os: "android",
            online: false, rdpUsername: "qa-user", sshUsername: "qa-user", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(ProfileExportBundle(profiles: [valid, invalid]))

        let result = try store.importData(data, merge: false)
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(store.profiles.map(\.id), ["box"])
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

    func testMergeSkipsAndroidPeer() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        let android = TailscalePeer(
            id: "phone", hostName: "phone", dnsName: "phone.ts.net", os: "android",
            ipv4: "100.64.0.9", online: true, isSelf: false
        )
        store.merge(peers: [android])
        XCTAssertTrue(store.profiles.isEmpty)
    }
}

final class CredentialStoreTests: XCTestCase {
    func testRoundTripSaveLoadRemove() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/credentials.json")
        let store = CredentialStore(testFileURL: url)
        XCTAssertFalse(store.hasPassword(for: "dev"))
        XCTAssertTrue(store.set("secret", for: "dev"))
        XCTAssertEqual(store.password(for: "dev"), "secret")
        XCTAssertTrue(store.hasPassword(for: "dev"))
        store.remove(for: "dev")
        XCTAssertNil(store.password(for: "dev"))
    }

    func testEmptyPasswordRemovesEntry() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/credentials.json")
        let store = CredentialStore(testFileURL: url)
        XCTAssertTrue(store.set("x", for: "a"))
        XCTAssertTrue(store.set("   ", for: "a"))
        XCTAssertFalse(store.hasPassword(for: "a"))
    }

    func testTrimsPasswordWhitespace() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/credentials.json")
        let store = CredentialStore(testFileURL: url)
        XCTAssertTrue(store.set("  pass  ", for: "h"))
        XCTAssertEqual(store.password(for: "h"), "pass")
    }
}

@MainActor
final class ProfileStoreFixtureTests: XCTestCase {
    func testLoadProductionScaleFixture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sanitized-production-profiles.json")
        let data = try Data(contentsOf: fixtureURL)
        let profiles = try JSONDecoder().decode([HostProfile].self, from: data)
        XCTAssertEqual(profiles.count, 40)
        XCTAssertTrue(profiles.allSatisfy { HostOS.isAllowedProfile($0.os) })
        XCTAssertFalse(profiles.contains { $0.os == "android" })
        XCTAssertTrue(profiles.contains { $0.os == "linux" && $0.online })
        XCTAssertTrue(profiles.contains { !$0.online })
        XCTAssertTrue(profiles.contains { $0.settings.width == 1366 && $0.settings.height == 768 })
    }

    func testFixtureRoundTripThroughStore() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sanitized-production-profiles.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoded = try JSONDecoder().decode([HostProfile].self, from: data)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        store.profiles = decoded
        store.save()
        store.load()
        XCTAssertEqual(store.profiles.count, 40)
        for original in decoded {
            let loaded = store.profile(id: original.id)
            XCTAssertEqual(loaded?.displayName, original.displayName)
            XCTAssertEqual(loaded?.settings.displayMode, original.settings.displayMode)
        }
    }

    func testVisibleProfilesFiltersOffline() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        store.profiles = [
            HostProfile(
                id: "on", hostName: "on", displayName: "On", address: "1", os: "linux",
                online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
                settings: .default, lastRemoteDir: ""
            ),
            HostProfile(
                id: "off", hostName: "off", displayName: "Off", address: "2", os: "linux",
                online: false, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
                settings: .default, lastRemoteDir: ""
            ),
        ]
        let defaults = UserDefaults.standard
        let key = AppSettingsKey.showOffline
        let prior = defaults.bool(forKey: key)
        defer { defaults.set(prior, forKey: key) }
        defaults.set(false, forKey: key)
        XCTAssertEqual(store.visibleProfiles.count, 1)
        XCTAssertEqual(store.visibleProfiles.first?.id, "on")
        defaults.set(true, forKey: key)
        XCTAssertEqual(store.visibleProfiles.count, 2)
    }

    func testReconcileSelectionMovesOffHiddenOfflineHost() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        store.profiles = [
            HostProfile(
                id: "on", hostName: "on", displayName: "On", address: "1", os: "linux",
                online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
                settings: .default, lastRemoteDir: ""
            ),
            HostProfile(
                id: "off", hostName: "off", displayName: "Off", address: "2", os: "linux",
                online: false, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
                settings: .default, lastRemoteDir: ""
            ),
        ]
        let defaults = UserDefaults.standard
        let key = AppSettingsKey.showOffline
        let prior = defaults.bool(forKey: key)
        defer { defaults.set(prior, forKey: key) }
        defaults.set(false, forKey: key)
        XCTAssertEqual(store.reconcileSelection("off"), "on")
        XCTAssertEqual(store.reconcileSelection("on"), "on")
        defaults.set(true, forKey: key)
        XCTAssertEqual(store.reconcileSelection("off"), "off")
    }

    func testAddManualHostValidation() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let store = ProfileStore(testProfilesURL: url)
        XCTAssertEqual(store.addManualHost(displayName: "", address: "1.2.3.4"), "Display name is required.")
        XCTAssertEqual(store.addManualHost(displayName: "Box", address: ""), "Address is required.")
        XCTAssertNil(store.addManualHost(displayName: "Box", address: "100.64.0.5"))
        XCTAssertEqual(store.addManualHost(displayName: "Box", address: "100.64.0.6"), "A host named \"Box\" already exists.")

        // QA-010: discovered host with hostname id but same display name must also collide.
        var discovered = HostProfile(
            id: "host-01", hostName: "host-01", displayName: "Render Node", address: "100.64.0.7",
            os: "linux", online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        discovered.normalizeCredentials()
        store.profiles.append(discovered)
        XCTAssertEqual(
            store.addManualHost(displayName: "render node", address: "100.64.0.8"),
            "A host named \"render node\" already exists."
        )
    }

    func testLoadDropsNonRDPCapableProfiles() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TailRDPTests-\(UUID().uuidString)/profiles.json")
        let invalid = HostProfile(
            id: "phone", hostName: "phone", displayName: "Phone", address: "9.9.9.9", os: "android",
            online: false, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let valid = HostProfile(
            id: "box", hostName: "box", displayName: "Box", address: "1.1.1.1", os: "linux",
            online: true, rdpUsername: "u", sshUsername: "u", rdpPort: 3389,
            settings: .default, lastRemoteDir: ""
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        let store = ProfileStore(testProfilesURL: url)
        try enc.encode([invalid, valid]).write(to: url)
        store.load()
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.id, "box")
        let saved = try JSONDecoder().decode([HostProfile].self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, "box")
    }
}

final class RDPSettingsLegacyTests: XCTestCase {
    func testLegacySmartReconnectFieldNames() throws {
        let json = """
        {"width":1920,"height":1080,"autoDiagnoseOnFailure":false}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(RDPSettings.self, from: json)
        XCTAssertFalse(settings.smartReconnect)
    }

    func testConflictingFullscreenFlagsNormalizedOnDecode() throws {
        let json = """
        {"fullscreen":true,"dynamicResolution":true,"multiMonitor":true}
        """.data(using: .utf8)!
        let settings = try JSONDecoder().decode(RDPSettings.self, from: json)
        XCTAssertFalse(settings.dynamicResolution)
        XCTAssertFalse(settings.multiMonitor)
    }

    func testCustomResolutionDisplayLabel() {
        var settings = RDPSettings()
        settings.width = 1366
        settings.height = 768
        XCTAssertEqual(settings.displayMode, .window)
        XCTAssertEqual(settings.connectSummary, "1366×768, AVC420, lan")
    }
}

final class ProcessRunnerTests: XCTestCase {
    /// Regression: sequential pipe reads deadlocked when a child filled the 64KB
    /// stderr buffer while stdout was still open (commit 91eb661).
    func testConcurrentDrainOfLargeStdoutAndStderr() {
        let result = ProcessRunner.run(
            "/bin/sh",
            ["-c", "dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'o'; dd if=/dev/zero bs=1024 count=200 2>/dev/null | tr '\\0' 'e' 1>&2"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, 200 * 1024)
        XCTAssertEqual(result.stderr.count, 200 * 1024)
    }

    /// Regression: writing stdin to a child that exited without reading raised
    /// an uncatchable NSException (EPIPE) with the legacy FileHandle.write API.
    func testStdinToFastExitingChildDoesNotCrash() {
        let big = String(repeating: "x", count: 1_000_000)
        let result = ProcessRunner.run("/bin/sh", ["-c", "exit 7"], stdin: big)
        XCTAssertEqual(result.exitCode, 7)
    }

    func testStdinDelivered() {
        let result = ProcessRunner.run("/bin/cat", [], stdin: "hello")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.stdout, "hello")
    }
}

final class AppDataDirTests: XCTestCase {
    func testOverrideHonored() {
        setenv("TAILRDP_DATA_DIR", "/tmp/tailrdp-qa-data", 1)
        defer { unsetenv("TAILRDP_DATA_DIR") }
        XCTAssertEqual(AppDataDir.base.path, "/tmp/tailrdp-qa-data")
    }

    func testDefaultIsApplicationSupport() {
        unsetenv("TAILRDP_DATA_DIR")
        XCTAssertTrue(AppDataDir.base.path.hasSuffix("Application Support/TailRDP"))
    }

    func testQABooleanArgumentParsing() {
        XCTAssertEqual(AppLaunchOverrides.parseBool(" YES "), true)
        XCTAssertEqual(AppLaunchOverrides.parseBool("off"), false)
        XCTAssertNil(AppLaunchOverrides.parseBool("maybe"))
    }

    func testRemoteIOKillSwitchReadsQAEnvironment() {
        setenv("TAILRDP_DISABLE_REMOTE_IO", "1", 1)
        defer { unsetenv("TAILRDP_DISABLE_REMOTE_IO") }
        XCTAssertTrue(SFTPService.remoteIODisabled)
    }
}

final class DependencyWarningTests: XCTestCase {
    func testConfiguredExecutableOverridesSatisfyDependencyCheck() {
        XCTAssertTrue(
            ContentView.missingDependencyNames(
                freerdpOverride: "/usr/bin/false",
                tailscaleOverride: "/usr/bin/false"
            ).isEmpty
        )
    }

}

final class FileTransferPathTests: XCTestCase {
    func testRemoteHomeFallbackKeepsAbsoluteHomePath() {
        XCTAssertEqual(
            FileTransferView.remoteHomeFallback(for: "/home/qa-user/projects", sshUsername: "fallback"),
            "/home/qa-user"
        )
        XCTAssertEqual(
            FileTransferView.remoteHomeFallback(for: "/Users/qa-user/Documents", sshUsername: "fallback"),
            "/Users/qa-user"
        )
        XCTAssertEqual(
            FileTransferView.remoteHomeFallback(for: "/tmp", sshUsername: "qa-user"),
            "/home/qa-user"
        )
    }
}

final class WakeOnLANTests: XCTestCase {
    private let mac = "74:56:3c:68:55:b4"

    func testMagicPacketIsSyncStreamPlusSixteenRepeats() {
        guard let packet = WakeOnLAN.magicPacket(mac: mac) else {
            return XCTFail("valid MAC produced no packet")
        }
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), Array(repeating: 0xFF, count: 6))
        let expected = Data([0x74, 0x56, 0x3c, 0x68, 0x55, 0xb4])
        for repeatIndex in 0..<16 {
            let start = 6 + repeatIndex * 6
            XCTAssertEqual(packet[start..<(start + 6)], expected, "repeat \(repeatIndex)")
        }
    }

    func testRejectsMalformedMACs() {
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "74:56:3c:68:55"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "74-56-3c-68-55-b4"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "zz:56:3c:68:55:b4"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: ""))
    }

    /// macOS `arp` prints octets unpadded, so the parser must pad them back.
    func testARPTableParsesUnpaddedOctets() {
        let line = "? (192.168.1.250) at da:8:94:66:ef:5a on en0 ifscope [ethernet]"
        XCTAssertEqual(WakeOnLAN.normalized(mac: "da:8:94:66:ef:5a"), "da:08:94:66:ef:5a")
        XCTAssertNotNil(line.range(of: "([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}", options: .regularExpression))
    }

    func testBroadcastAddressUsesSubnet() {
        XCTAssertEqual(WakeOnLAN.broadcastAddress(forLAN: "192.168.1.73"), "192.168.1.255")
        XCTAssertNil(WakeOnLAN.broadcastAddress(forLAN: "192.168.1"))
        XCTAssertNil(WakeOnLAN.broadcastAddress(forLAN: "not.an.ip.here"))
    }

    /// Broadcasting to a WAN endpoint's subnet would spray a stranger's network.
    func testOnlyPrivateEndpointsBecomeWakeTargets() {
        XCTAssertEqual(WakeOnLAN.lanAddress(fromCurAddr: "192.168.1.73:41641"), "192.168.1.73")
        XCTAssertEqual(WakeOnLAN.lanAddress(fromCurAddr: "10.253.233.20:41641"), "10.253.233.20")
        XCTAssertNil(WakeOnLAN.lanAddress(fromCurAddr: "84.46.93.12:41641"))
        XCTAssertNil(WakeOnLAN.lanAddress(fromCurAddr: "172.32.0.5:41641"))
        XCTAssertNil(WakeOnLAN.lanAddress(fromCurAddr: ""))
    }

    func testWakeNeedsBothMACAndLANAddress() {
        var profile = HostProfile.make(from: TailscalePeer(
            id: "host", hostName: "host", dnsName: "", os: "linux",
            ipv4: "100.0.0.1", online: false, isSelf: false
        ))
        XCTAssertFalse(profile.canWake)
        profile.wakeMAC = mac
        XCTAssertFalse(profile.canWake, "a MAC with no LAN address has no broadcast target")
        profile.wakeLANAddress = "192.168.1.73"
        XCTAssertTrue(profile.canWake)
    }

    func testLearnedMACSurvivesAProfileRoundTrip() throws {
        var profile = HostProfile.make(from: TailscalePeer(
            id: "host", hostName: "host", dnsName: "", os: "linux",
            ipv4: "100.0.0.1", online: false, isSelf: false
        ))
        profile.wakeMAC = mac
        profile.wakeLANAddress = "192.168.1.73"
        let decoded = try JSONDecoder().decode(
            HostProfile.self, from: JSONEncoder().encode(profile)
        )
        XCTAssertEqual(decoded.wakeMAC, mac)
        XCTAssertEqual(decoded.wakeLANAddress, "192.168.1.73")
    }

    /// The cached `online` flag went stale when a host died between refreshes, so Connect
    /// skipped the wake and dialed a powered-off box. The probe is the ground truth now.
    func testTCPProbeSeesAListenerAndItsAbsence() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // ephemeral
        XCTAssertEqual(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr), 1)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        var live = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &live) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        XCTAssertEqual(named, 0)
        let port = Int(live.sin_port.bigEndian)

        XCTAssertTrue(WakeOnLAN.acceptsTCP(host: "127.0.0.1", port: port, timeout: 2))
        close(fd)
        XCTAssertFalse(WakeOnLAN.acceptsTCP(host: "127.0.0.1", port: port, timeout: 2))
        XCTAssertFalse(
            WakeOnLAN.acceptsTCP(host: "192.0.2.1", port: 3389, timeout: 1),
            "TEST-NET-1 blackholes, so this must time out rather than report reachable"
        )
    }

    /// The bug this guards: CurAddr was the router's hairpin endpoint, so the learned MAC
    /// was the gateway's and the magic packet went nowhere.
    func testGatewayIsParsedFromRouteOutput() {
        let out = """
           route to: default
        destination: default
               mask: default
            gateway: 192.168.1.1
          interface: en0
        """
        XCTAssertEqual(WakeOnLAN.gatewayIPv4(fromRouteOutput: out), "192.168.1.1")
        XCTAssertNil(WakeOnLAN.gatewayIPv4(fromRouteOutput: "route: writing to routing socket: not in table"))
    }

    func testDiscoveryPullsLANEndpointFromCurAddr() {
        let json = """
        {"BackendState":"Running","Self":{"HostName":"mac","TailscaleIPs":["100.0.0.9"],"OS":"macOS"},
         "Peer":{"k":{"HostName":"box","TailscaleIPs":["100.0.0.1"],"OS":"linux","Online":true,
         "CurAddr":"192.168.1.73:41641"}}}
        """
        let peer = TailscaleService.parse(json)?.peers.first
        XCTAssertEqual(peer?.lanAddress, "192.168.1.73")
    }
}
