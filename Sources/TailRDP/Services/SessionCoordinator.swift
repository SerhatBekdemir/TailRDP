import Foundation

/// Orchestrates connect: last-good settings, crash-only recovery, plain-language status.
@MainActor
enum SessionCoordinator {
    private static let successThreshold: TimeInterval = SessionHealth.establishedSessionThreshold

    static func connect(
        profileID: String,
        store: ProfileStore,
        launcher: RDPLauncher,
        resumingPaused: Bool = false
    ) async -> (message: String, isError: Bool) {
        guard let base = store.profile(id: profileID) else {
            return ("Host not found.", true)
        }

        var statusParts: [String] = []
        let useFallback = base.health.usingSafeFallback || base.health.consecutiveFailures >= 2

        let isLinuxResume = base.os == "linux"
            && (resumingPaused || base.health.lastEndKind == .paused || base.stickyBanner?.style == .paused)

        // Gnome Remote Desktop can hang if the client reconnects before the prior
        // RDP socket is fully torn down — give Linux hosts a moment after pause.
        if isLinuxResume {
            let delayMs = base.health.linuxResumeDelayMs
            AppLog.session.info("Linux resume delay \(delayMs)ms for \(profileID, privacy: .public)")
            try? await Task.sleep(for: .milliseconds(delayMs))
        }

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
        if isLinuxResume {
            statusParts.append("Resuming paused session")
        } else if useFallback {
            statusParts.append("Connecting with safe fallback (\(RDPSettings.safeFallback.connectSummary))")
        } else if let last = base.lastWorking {
            statusParts.append("Connecting with last good settings (\(last.settings.connectSummary))")
        } else {
            statusParts.append("Connecting (\(launchProfile.settings.connectSummary))")
        }

        if let err = await launcher.launch(profile: launchProfile) {
            store.update(id: profileID) { p in
                var h = p.health
                h.consecutiveFailures += 1
                h.lastFailureSummary = err
                if !isLinuxResume {
                    h.lastEndKind = .crashed
                }
                if isLinuxResume {
                    h.linuxResumeDelayMs = min(
                        SessionHealth.maxLinuxResumeDelayMs,
                        h.linuxResumeDelayMs + SessionHealth.resumeDelayBackoffMs
                    )
                }
                p.sessionHealth = h
            }
            AppLog.session.error("Connect failed for \(profileID, privacy: .public): \(err, privacy: .public)")
            return (err, true)
        }

        if isLinuxResume {
            store.update(id: profileID) { p in
                var h = p.health
                h.linuxResumeDelayMs = max(
                    SessionHealth.minLinuxResumeDelayMs,
                    h.linuxResumeDelayMs - SessionHealth.resumeDelayStepMs
                )
                p.sessionHealth = h
            }
        }

        AppLog.session.info("Connected to \(profileID, privacy: .public)")

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
            let resolved = await resolvePausedLoggedOutOrCrash(notice: notice, store: store)
            if resolved.kind == .crashed {
                return await handleCrashEnd(
                    notice: notice,
                    duration: duration,
                    used: used,
                    store: store,
                    prefetchedReport: resolved.report
                )
            }
            if resolved.kind == .loggedOut {
                store.update(id: notice.profileID) { p in
                    var h = SessionHealth()
                    h.lastEndKind = .loggedOut
                    p.sessionHealth = h
                }
                return SessionEndOutcome(message: "Remote session ended.", kind: .loggedOut)
            }
            recordSuccessfulSettings(profileID: notice.profileID, used: used, duration: duration, store: store)
            store.update(id: notice.profileID) { p in
                var h = SessionHealth()
                h.lastEndKind = .paused
                p.sessionHealth = h
            }
            let sshNote = resolved.sshUnknown
                ? "SSH is unavailable. The remote session may still be running."
                : nil
            return SessionEndOutcome(
                message: resolved.sshUnknown
                    ? "Session ended — couldn't verify remote state"
                    : notice.message,
                kind: .paused,
                fixSummary: sshNote,
                actionLabel: "Resume",
                sshUnverified: resolved.sshUnknown
            )

        case .crashed:
            return await handleCrashEnd(notice: notice, duration: duration, used: used, store: store)
        }
    }

    static func promoteCurrentSettings(profileID: String, store: ProfileStore) {
        store.update(id: profileID, immediate: true) { p in
            p.lastWorking = LastWorkingSnapshot(settings: p.settings, savedAt: Date())
            p.sessionHealth = SessionHealth()
            p.stickyBanner = nil
        }
    }

    /// End a paused remote session on the host (Linux via SSH) and clear the sticky banner.
    static func disconnectRemotePausedSession(
        profileID: String,
        store: ProfileStore
    ) async -> (message: String, isError: Bool) {
        guard let profile = store.profile(id: profileID) else {
            return ("Host not found.", true)
        }

        if profile.os == "linux" {
            let result = await Task.detached {
                RemoteDisplayRecovery.terminateRemoteSessions(profile)
            }.value
            switch result {
            case .failure(let err):
                return (err.message, true)
            case .success(let detail):
                store.clearPausedSession(profileID: profileID)
                store.update(id: profileID, immediate: true) { p in
                    var h = SessionHealth()
                    h.lastEndKind = .loggedOut
                    p.sessionHealth = h
                }
                store.setFlashBanner(
                    profileID: profileID,
                    banner: HostFlashBanner(text: "Remote session ended.", style: .success)
                )
                let msg = detail.isEmpty ? "Remote session ended." : "Remote session ended. \(detail.capitalized)."
                return (msg, false)
            }
        }

        // Non-Linux: no SSH hook to log off a paused RDP session — clear local state only.
        store.clearPausedSession(profileID: profileID)
        store.update(id: profileID, immediate: true) { p in
            var h = SessionHealth()
            h.lastEndKind = .loggedOut
            p.sessionHealth = h
        }
        store.setFlashBanner(
            profileID: profileID,
            banner: HostFlashBanner(
                text: "Marked disconnected. The remote session may still be running on the host.",
                style: .success
            )
        )
        return ("Marked disconnected.", false)
    }

    // MARK: - Private

    private struct PausedResolution: Equatable {
        var kind: SessionEndKind
        var sshUnknown: Bool = false
        var report: RemoteSessionReport?
    }

    private static func resolvePausedLoggedOutOrCrash(
        notice: SessionEndNotice,
        store: ProfileStore
    ) async -> PausedResolution {
        guard let profile = store.profile(id: notice.profileID), profile.isLinux else {
            return PausedResolution(kind: .paused)
        }
        try? await Task.sleep(for: .milliseconds(800))

        let reportResult = await Task.detached {
            RemoteDisplayRecovery.discoverFailure(profile)
        }.value

        guard case .success(let report) = reportResult else {
            return PausedResolution(kind: .paused, sshUnknown: true)
        }
        if RemoteDisplayRecovery.looksLikeRecentCrash(report) {
            return PausedResolution(kind: .crashed, report: report)
        }
        let kind: SessionEndKind = report.remoteSessionIDs.isEmpty ? .loggedOut : .paused
        return PausedResolution(kind: kind, report: report)
    }

    private static func handleCrashEnd(
        notice: SessionEndNotice,
        duration: TimeInterval,
        used: RDPSettings,
        store: ProfileStore,
        prefetchedReport: RemoteSessionReport? = nil
    ) async -> SessionEndOutcome {
        guard let profile = store.profile(id: notice.profileID) else {
            return SessionEndOutcome(message: notice.message, kind: notice.endKind)
        }

        if isAuthenticationFailure(notice) {
            store.update(id: notice.profileID) { p in
                var h = p.health
                h.lastFailureSummary = notice.message
                h.lastEndKind = .crashed
                p.sessionHealth = h
            }
            return SessionEndOutcome(
                message: "Sign-in failed. Update your username or password.",
                kind: .crashed,
                actionLabel: "Update sign-in",
                needsCredentials: true
            )
        }

        let errInfo = notice.errInfoCode ?? extractErrInfo(from: notice.message)
        var report = prefetchedReport
        if report == nil, profile.isLinux {
            let discovered = await Task.detached {
                RemoteDisplayRecovery.discoverFailure(profile)
            }.value
            if case .success(let r) = discovered { report = r }
        }

        let preset = RemoteDisplayRecovery.chooseRecovery(
            errInfo: errInfo,
            report: report,
            failureCount: profile.health.consecutiveFailures + 1
        )

        var fixSummary: String?
        if profile.settings.smartReconnect, profile.os == "linux", preset != .none {
            let applied = await Task.detached {
                RemoteDisplayRecovery.apply(preset, profile: profile)
            }.value
            switch applied {
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
        let report: RemoteSessionReport? = await Task.detached {
            switch RemoteDisplayRecovery.discoverFailure(profile) {
            case .failure: return nil
            case .success(let r): return r
            }
        }.value
        let preset = RemoteDisplayRecovery.chooseRecovery(
            errInfo: profile.health.lastFailureSummary.flatMap { extractErrInfo(from: $0) },
            report: report,
            failureCount: profile.health.consecutiveFailures
        )
        guard preset != .none else { return nil }
        let applied = await Task.detached {
            RemoteDisplayRecovery.apply(preset, profile: profile)
        }.value
        switch applied {
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

    private static func isAuthenticationFailure(_ notice: SessionEndNotice) -> Bool {
        notice.message.contains("Could not authenticate")
            || notice.message.contains("Sign-in failed")
            || notice.message.contains("AUTHENTICATION_FAILED")
    }
}
