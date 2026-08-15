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
        let useFallback = base.usesSafeFallback

        // A host that is powered off answers neither SSH nor RDP, so waking comes before
        // healing and before the settle wait below. The probe, not `online`, decides:
        // that flag is a cached discovery result and a host can die between refreshes.
        if base.canWake, await !WakeOnLAN.rdpIsUp(profile: base),
           let woke = await wakeHost(profile: base, store: store) {
            statusParts.append(woke)
        }

        let isLinuxResume = base.isLinux
            && (resumingPaused || base.health.lastEndKind == .paused || base.stickyBanner?.style == .paused)

        // Only heal before connect after a prior crash — never after pause or logout.
        // Runs before the settle wait below: healing can itself end remote sessions.
        if base.isLinux,
           base.health.consecutiveFailures > 0,
           base.health.lastEndKind == .crashed,
           base.settings.smartReconnect {
            if let healed = await healBeforeConnect(profile: base) {
                statusParts.append(healed)
            }
        }

        // Gnome Remote Desktop can hang if the client reconnects before the prior
        // RDP socket is fully torn down — give Linux hosts a moment after pause.
        // A session that fully ended is worse than a pause: gnome-remote-desktop
        // must respawn the login screen and hand the RDP connection over to it, and
        // a client that connects mid-respawn gets a redirect the greeter never
        // accepts — an unrecoverable black window, with no client exit to detect.
        let secondsSinceRemoteEnd = Self.remoteSessionEndedAt[profileID]
            .map { Date().timeIntervalSince($0) }
        if let delayMs = Self.linuxSettleDelayMs(
            profile: base,
            isLinuxResume: isLinuxResume,
            secondsSinceRemoteEnd: secondsSinceRemoteEnd
        ) {
            AppLog.session.info("Linux settle delay \(delayMs)ms for \(profileID, privacy: .public)")
            // A multi-second wait behind a bare spinner reads as a hang — say why.
            if delayMs >= SessionHealth.linuxRestartSettleDelayMs {
                store.setFlashBanner(
                    profileID: profileID,
                    banner: HostFlashBanner(
                        text: "Waiting for the host's login screen to come back…",
                        style: .paused
                    )
                )
            }
            try? await Task.sleep(for: .milliseconds(delayMs))
        }

        let launchProfile = base.profileForConnect()
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
                p.health.consecutiveFailures += 1
                p.health.lastFailureSummary = err
                if isLinuxResume {
                    p.health.linuxResumeDelayMs = min(
                        SessionHealth.maxLinuxResumeDelayMs,
                        p.health.linuxResumeDelayMs + SessionHealth.resumeDelayBackoffMs
                    )
                } else {
                    p.health.lastEndKind = .crashed
                }
            }
            AppLog.session.error("Connect failed for \(profileID, privacy: .public): \(err, privacy: .public)")
            return (err, true)
        }

        if isLinuxResume {
            store.update(id: profileID) { p in
                p.health.linuxResumeDelayMs = max(
                    SessionHealth.minLinuxResumeDelayMs,
                    p.health.linuxResumeDelayMs - SessionHealth.resumeDelayStepMs
                )
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
                p.sessionHealth = SessionHealth(lastEndKind: .loggedOut)
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
                    p.sessionHealth = SessionHealth(lastEndKind: .loggedOut)
                }
                return SessionEndOutcome(message: "Remote session ended.", kind: .loggedOut)
            }
            recordSuccessfulSettings(profileID: notice.profileID, used: used, duration: duration, store: store)
            store.update(id: notice.profileID) { p in
                p.sessionHealth = SessionHealth(lastEndKind: .paused)
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

    /// Wall-clock of the last remote session TailRDP ended, per host. In memory only:
    /// the handover race exists only between that teardown and the next connect in the
    /// same run. A relaunched app is already past it.
    private static var remoteSessionEndedAt: [String: Date] = [:]

    static func noteRemoteSessionEnded(profileID: String) {
        remoteSessionEndedAt[profileID] = Date()
    }

    /// How long to wait before connecting a Linux host, or nil for no wait.
    ///
    /// Resuming a paused session only waits for the old RDP socket to clear. A session
    /// TailRDP just ended waits longer: gnome-remote-desktop has to bring the login
    /// screen back and hand the connection over to it. Time the user already spent
    /// counts against that wait, so a slow click costs nothing extra and a host left
    /// alone for an hour is not taxed at all.
    ///
    /// ponytail: fixed delay, not a readiness probe — a host slower than
    /// `linuxRestartSettleDelayMs` still races. Upgrade path: poll the host over SSH
    /// until its greeter session stops churning, and keep this as the timeout.
    static func linuxSettleDelayMs(
        profile: HostProfile,
        isLinuxResume: Bool,
        secondsSinceRemoteEnd: TimeInterval?
    ) -> Int? {
        guard profile.isLinux else { return nil }
        if let elapsed = secondsSinceRemoteEnd {
            let target = max(profile.health.linuxResumeDelayMs, SessionHealth.linuxRestartSettleDelayMs)
            let remaining = target - Int(elapsed * 1000)
            if remaining > 0 { return remaining }
        }
        return isLinuxResume ? profile.health.linuxResumeDelayMs : nil
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

        if profile.isLinux {
            let result = await Task.detached {
                RemoteDisplayRecovery.terminateRemoteSessions(profile)
            }.value
            switch result {
            case .failure(let err):
                return (err.message, true)
            case .success(let detail):
                noteRemoteSessionEnded(profileID: profileID)
                store.clearPausedSession(profileID: profileID)
                store.update(id: profileID, immediate: true) { p in
                    p.sessionHealth = SessionHealth(lastEndKind: .loggedOut)
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
            p.sessionHealth = SessionHealth(lastEndKind: .loggedOut)
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

    /// How long to wait for a woken host to appear on the tailnet.
    static let wakeTimeout: TimeInterval = 90
    /// Breathing room after the tunnel comes up, before dialing RDP.
    static let wakeGrace: Duration = .seconds(5)
    /// How long to wait for the RDP port after that.
    static let rdpReadyTimeout: TimeInterval = 30

    // MARK: - Private

    /// Send a magic packet to an offline host and wait for the tailnet to see it.
    /// Returns a status fragment, or nil when no packet could be sent.
    ///
    /// A timeout does not abort the connect: TailRDP has always let you dial a host that
    /// looks offline using its saved address, and discovery can lag a host already up.
    private static func wakeHost(profile: HostProfile, store: ProfileStore) async -> String? {
        guard WakeOnLAN.wake(profile: profile) else { return nil }
        store.setFlashBanner(
            profileID: profile.id,
            banner: HostFlashBanner(text: "Waking \(profile.displayName)…", style: .paused)
        )
        guard await WakeOnLAN.waitForPeerOnline(peerID: profile.id, timeout: wakeTimeout) else {
            AppLog.session.info("Wake timed out for \(profile.id, privacy: .public)")
            return "Sent a wake signal, but the host has not come back yet"
        }
        store.update(id: profile.id) { $0.online = true }
        // tailscaled beats the RDP server to the network on a cold boot, so wait for the
        // port itself. The floor stays: a server that accepts instantly still needs a
        // moment before it will negotiate.
        try? await Task.sleep(for: wakeGrace)
        _ = await WakeOnLAN.waitForRDP(profile: profile, timeout: rdpReadyTimeout)
        AppLog.session.info("Woke \(profile.id, privacy: .public)")
        return "Woke \(profile.displayName)"
    }

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
                p.health.lastFailureSummary = notice.message
                p.health.lastEndKind = .crashed
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
        if profile.settings.smartReconnect, profile.isLinux, preset != .none {
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
            p.health.consecutiveFailures += 1
            p.health.lastFailureSummary = notice.message
            p.health.lastEndKind = .crashed
            if preset == .useSafeClientSettings {
                p.health.usingSafeFallback = true
                p.lastWorking = nil
            }
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
            // These presets end remote sessions, so the host is respawning its login
            // screen — the connect below has to wait for the handover, same as a
            // force-stop does.
            if preset == .endStuckSessions || preset == .resetRemoteDesktop {
                noteRemoteSessionEnded(profileID: profile.id)
            }
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
