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
        XCTAssertTrue(args.contains("/cert:tofu"))
        XCTAssertFalse(args.contains("/cert:ignore"))
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
