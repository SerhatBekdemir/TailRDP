import Foundation

/// Orchestrates connect: last-good settings, crash-only recovery, plain-language status.
@MainActor
enum SessionCoordinator {
    private static let successThreshold: TimeInterval = 45

    static func connect(
        profileID: String,
        store: ProfileStore,
        launcher: RDPLauncher
    ) async -> (message: String, isError: Bool) {
        guard let base = store.profile(id: profileID) else {
            return ("Host not found.", true)
        }

        var statusParts: [String] = []
        let useFallback = base.health.usingSafeFallback || base.health.consecutiveFailures >= 2

        // Only heal before connect after a prior crash — never after pause or logout.
        if base.os == "linux",
           base.health.consecutiveFailures > 0,
           base.health.lastEndKind == .crashed,
           base.settings.smartReconnect {
            if let healed = await healBeforeConnect(profile: base) {
                statusParts.append(healed)
            }
        }

        let launchProfile = profileForLaunch(base)
        if useFallback {
            statusParts.append("Connecting with safe fallback (\(RDPSettings.safeFallback.connectSummary))")
        } else if let last = base.lastWorking {
            statusParts.append("Connecting with last good settings (\(last.settings.connectSummary))")
        } else {
            statusParts.append("Connecting (\(launchProfile.settings.connectSummary))")
        }

        if let err = launcher.launch(profile: launchProfile) {
            store.update(id: profileID) { p in
                var h = p.health
                h.consecutiveFailures += 1
                h.lastFailureSummary = err
                h.lastEndKind = .crashed
                p.sessionHealth = h
            }
            return (err, true)
        }

        let msg = statusParts.joined(separator: ". ") + "."
        return (msg, false)
    }

    static func handleSessionEnd(
        notice: SessionEndNotice,
        duration: TimeInterval,
        store: ProfileStore,
        launcher: RDPLauncher
    ) async -> SessionEndOutcome {
        guard let used = launcher.lastUsedSettings(for: notice.profileID) else {
            return SessionEndOutcome(message: notice.message, kind: notice.endKind)
        }

        switch notice.endKind {
        case .loggedOut:
            recordSuccessfulSettings(profileID: notice.profileID, used: used, duration: duration, store: store)
            store.update(id: notice.profileID) { p in
                var h = SessionHealth()
                h.lastEndKind = .loggedOut
                p.sessionHealth = h
            }
            return SessionEndOutcome(message: "Disconnected.", kind: .loggedOut)

        case .paused:
            let kind = await resolvePausedLoggedOutOrCrash(notice: notice, store: store)
            if kind == .crashed {
                return await handleCrashEnd(notice: notice, duration: duration, used: used, store: store)
            }
            recordSuccessfulSettings(profileID: notice.profileID, used: used, duration: duration, store: store)
            store.update(id: notice.profileID) { p in
                var h = SessionHealth()
                h.lastEndKind = kind
                p.sessionHealth = h
            }
            if kind == .loggedOut {
                return SessionEndOutcome(message: "Disconnected.", kind: .loggedOut)
            }
            return SessionEndOutcome(
                message: notice.message,
                kind: .paused,
                actionLabel: "Resume"
            )

        case .crashed:
            return await handleCrashEnd(notice: notice, duration: duration, used: used, store: store)
        }
    }

    static func promoteCurrentSettings(profileID: String, store: ProfileStore) {
        store.update(id: profileID) { p in
            p.lastWorking = LastWorkingSnapshot(settings: p.settings, savedAt: Date())
            p.sessionHealth = SessionHealth()
        }
    }

    // MARK: - Private

    private static func resolvePausedLoggedOutOrCrash(
        notice: SessionEndNotice,
        store: ProfileStore
    ) async -> SessionEndKind {
        guard let profile = store.profile(id: notice.profileID), profile.os == "linux" else {
            return .paused
        }
        try? await Task.sleep(for: .milliseconds(800))

        let report = await Task.detached {
            RemoteDisplayRecovery.discoverFailure(profile)
        }.value

        if case .success(let r) = report, RemoteDisplayRecovery.looksLikeRecentCrash(r) {
            return .crashed
        }

        let active = await Task.detached {
            RemoteDisplayRecovery.hasActiveRemoteSession(profile)
        }.value
        return active ? .paused : .loggedOut
    }

    private static func handleCrashEnd(
        notice: SessionEndNotice,
        duration: TimeInterval,
        used: RDPSettings,
        store: ProfileStore
    ) async -> SessionEndOutcome {
        let errInfo = notice.errInfoCode ?? extractErrInfo(from: notice.message)
        var report: RemoteSessionReport?
        if store.profile(id: notice.profileID)?.os == "linux" {
            if case .success(let r) = RemoteDisplayRecovery.discoverFailure(
                store.profile(id: notice.profileID)!
            ) {
                report = r
            }
        }

        let profile = store.profile(id: notice.profileID)!
        let preset = RemoteDisplayRecovery.chooseRecovery(
            errInfo: errInfo,
            report: report,
            failureCount: profile.health.consecutiveFailures + 1
        )

        var fixSummary: String?
        if profile.settings.smartReconnect, profile.os == "linux", preset != .none {
            switch RemoteDisplayRecovery.apply(preset, profile: profile) {
            case .failure(let err):
                fixSummary = "Could not auto-fix: \(err.message)"
            case .success(let detail):
                let label = RemoteDisplayRecovery.plainRecoveryLabel(preset)
                if !label.isEmpty { fixSummary = label }
                if !detail.isEmpty, preset != .useSafeClientSettings {
                    fixSummary = [fixSummary, detail.capitalized].compactMap { $0 }.joined(separator: ". ")
                }
            }
        }

        store.update(id: notice.profileID) { p in
            var h = p.health
            h.consecutiveFailures += 1
            h.lastFailureSummary = notice.message
            h.lastEndKind = .crashed
            if preset == .useSafeClientSettings {
                h.usingSafeFallback = true
                p.lastWorking = nil
            }
            p.sessionHealth = h
        }

        // Preserve last-good settings from sessions that ran long enough before crashing.
        recordSuccessfulSettings(
            profileID: notice.profileID,
            used: used,
            duration: duration,
            store: store
        )

        var message = "Connection lost unexpectedly."
        if duration < 15 { message += " The session ended very quickly." }
        if fixSummary == nil { message += " \(notice.message)" }

        return SessionEndOutcome(
            message: message,
            kind: .crashed,
            fixSummary: fixSummary,
            actionLabel: "Reconnect"
        )
    }

    private static func recordSuccessfulSettings(
        profileID: String,
        used: RDPSettings,
        duration: TimeInterval,
        store: ProfileStore
    ) {
        guard duration >= successThreshold else { return }
        store.update(id: profileID) { p in
            p.lastWorking = LastWorkingSnapshot(settings: used, savedAt: Date())
        }
    }

    private static func profileForLaunch(_ profile: HostProfile) -> HostProfile {
        var p = profile
        if profile.health.usingSafeFallback || profile.health.consecutiveFailures >= 2 {
            p.settings = .safeFallback
        } else if let last = profile.lastWorking {
            p.settings = last.settings
        }
        return p
    }

    private static func healBeforeConnect(profile: HostProfile) async -> String? {
        let report: RemoteSessionReport?
        switch RemoteDisplayRecovery.discoverFailure(profile) {
        case .failure: report = nil
        case .success(let r): report = r
        }
        let preset = RemoteDisplayRecovery.chooseRecovery(
            errInfo: profile.health.lastFailureSummary.flatMap { extractErrInfo(from: $0) },
            report: report,
            failureCount: profile.health.consecutiveFailures
        )
        guard preset != .none else { return nil }
        switch RemoteDisplayRecovery.apply(preset, profile: profile) {
        case .failure: return nil
        case .success(let detail):
            var msg = RemoteDisplayRecovery.plainRecoveryLabel(preset)
            if !detail.isEmpty, preset != .useSafeClientSettings { msg += " — \(detail)" }
            return msg.isEmpty ? nil : msg
        }
    }

    private static func extractErrInfo(from message: String) -> String? {
        guard let range = message.range(of: "ERRINFO_[A-Z0-9_]+", options: .regularExpression) else {
            return nil
        }
        return String(message[range])
    }
}
