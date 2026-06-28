import Foundation

/// Live integration checks against a tailnet host (no UI). Invoked via `--qa-integration <match>`.
@MainActor
enum QAIntegration {
  static func run(hostMatch: String) async -> Int {
    var failures = 0
    func check(_ ok: Bool, _ name: String) {
      if ok { print("OK  \(name)") }
      else { print("FAIL \(name)"); failures += 1 }
    }

    print("=== TailRDP live integration (host match: \(hostMatch)) ===")
    fflush(stdout)

    failures += SessionEndClassifier.runBuiltInChecks()

    let store = ProfileStore()
    guard let profile = store.profiles.first(where: {
      $0.id.localizedCaseInsensitiveContains(hostMatch)
        || $0.displayName.localizedCaseInsensitiveContains(hostMatch)
    }) else {
      print("FAIL no profile matching \"\(hostMatch)\"")
      return failures + 1
    }
    print("… using profile \(profile.id) @ \(profile.address)")

    // Tailscale discovery
    let tailscale = TailscaleService()
    tailscale.refresh()
    for _ in 0..<30 {
      try? await Task.sleep(for: .milliseconds(200))
      if !tailscale.isRefreshing { break }
    }
    check(tailscale.lastError == nil, "Tailscale refresh (\(tailscale.peers.count) peers)")
    let peer = tailscale.peers.first { $0.id == profile.id }
    check(peer?.online == true, "Tailscale reports host online")
    store.merge(peers: tailscale.peers)
    check(store.profile(id: profile.id)?.online == true, "ProfileStore merge marks host online")

    // Credentials (presence only — never print secrets)
    check(CredentialStore.shared.hasPassword(for: profile.id), "Saved sign-in present")
    check(!profile.rdpUsernameForConnect.isEmpty, "RDP username configured")

    // SSH / SFTP
    let home = await Task.detached { SFTPService.remoteHomeDirectory(profile) }.value
    check(home != nil, "SSH remote $HOME detection")
    if let home {
      let listing = await Task.detached { SFTPService.listRemote(profile, path: home) }.value
      switch listing {
      case .success(let entries):
        check(!entries.isEmpty, "SFTP list remote home (\(entries.count) entries)")
      case .failure(let err):
        check(false, "SFTP list remote home: \(err.message)")
      }
    }

    // Linux remote inspect (non-destructive)
    if profile.isLinux {
      let inspect = await Task.detached { RemoteDisplayRecovery.inspect(profile) }.value
      switch inspect {
      case .success(let report):
        check(true, "SSH remote inspect (sessions=\(report.remoteSessionIDs.count))")
        let state = await Task.detached { RemoteDisplayRecovery.remoteSessionState(profile) }.value
        check(state != .unknown, "Remote session state verified (\(state))")
      case .failure(let err):
        check(false, "SSH remote inspect: \(err.message)")
      }
    }

    // Export / import round-trip (temp file, no passwords)
    do {
      let exported = try store.exportData()
      let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("TailRDP-qa-\(UUID().uuidString).json")
      try exported.write(to: tmp)
      let importStore = ProfileStore(testProfilesURL: tmp.deletingLastPathComponent().appendingPathComponent("noop.json"))
      let result = try importStore.importData(exported, merge: false)
      check(result.imported >= 1, "Profile export/import (\(result.imported) imported)")
      try? FileManager.default.removeItem(at: tmp)
    } catch {
      check(false, "Profile export/import: \(error.localizedDescription)")
    }

    // RDP connect → brief session → disconnect
    let launcher = RDPLauncher()
    let connect = await SessionCoordinator.connect(
      profileID: profile.id,
      store: store,
      launcher: launcher
    )
    check(!connect.isError, "RDP launch (\(connect.message))")
    if !connect.isError {
      try? await Task.sleep(for: .seconds(6))
      check(launcher.isActive(profile.id), "RDP session active after 6s")
      launcher.disconnect(profileID: profile.id)
      for _ in 0..<25 {
        try? await Task.sleep(for: .milliseconds(200))
        if !launcher.isActive(profile.id) { break }
      }
      check(!launcher.isActive(profile.id), "RDP disconnect clears active session")
      if let notice = launcher.sessionEndNotice, notice.profileID == profile.id {
        let outcome = await SessionCoordinator.handleSessionEnd(
          notice: notice,
          duration: notice.durationSeconds,
          store: store,
          launcher: launcher
        )
        store.applySessionOutcome(profileID: profile.id, outcome: outcome)
        launcher.clearSessionEndNotice(for: profile.id)
        check(outcome.kind == .loggedOut, "Session end classified as loggedOut")
      } else {
        check(false, "Session end notice after disconnect")
      }
    }

    if failures == 0 {
      print("--- pause / resume cycle ---")
      let pauseFailures = await runPauseResumeCycle(
        profile: profile,
        store: store,
        launcher: launcher
      )
      failures += pauseFailures
    }

    if failures == 0 {
      print("All live integration checks passed.")
    } else {
      print("\(failures) live check(s) failed.")
    }
    return failures
  }

  private static func runPauseResumeCycle(
    profile: HostProfile,
    store: ProfileStore,
    launcher: RDPLauncher
  ) async -> Int {
    var failures = 0
    func record(_ ok: Bool, _ name: String) {
      if ok { print("OK  \(name)") }
      else { print("FAIL \(name)"); failures += 1 }
    }

    let connect = await SessionCoordinator.connect(
      profileID: profile.id,
      store: store,
      launcher: launcher
    )
    record(!connect.isError, "Pause test: RDP launch")
    guard !connect.isError else { return failures + 1 }

    try? await Task.sleep(for: .seconds(8))
    record(launcher.isActive(profile.id), "Pause test: session running")

    // Close the FreeRDP window (pause) without using TailRDP Disconnect.
    let closed = await Task.detached { closeFreeRDPWindow() }.value
    record(closed, "Pause test: closed RDP client window")

    for _ in 0..<40 {
      try? await Task.sleep(for: .milliseconds(250))
      if launcher.sessionEndNotice?.profileID == profile.id { break }
    }
    guard let notice = launcher.sessionEndNotice, notice.profileID == profile.id else {
      record(false, "Pause test: session end notice")
      return failures + 1
    }
    record(notice.endKind == .paused, "Pause test: classifier → paused")

    let outcome = await SessionCoordinator.handleSessionEnd(
      notice: notice,
      duration: notice.durationSeconds,
      store: store,
      launcher: launcher
    )
    store.applySessionOutcome(profileID: profile.id, outcome: outcome)
    launcher.clearSessionEndNotice(for: profile.id)
    switch outcome.kind {
    case .paused:
      record(true, "Pause test: coordinator → paused")
      record(store.profile(id: profile.id)?.hasPausedSession == true, "Pause test: sticky paused banner")
      let resume = await SessionCoordinator.connect(
        profileID: profile.id,
        store: store,
        launcher: launcher,
        resumingPaused: true
      )
      record(!resume.isError, "Pause test: resume launch")
      try? await Task.sleep(for: .seconds(4))
      record(launcher.isActive(profile.id), "Pause test: resumed session active")
    case .loggedOut:
      // Linux SSH may report inactive remote session after a short window close.
      record(true, "Pause test: coordinator → loggedOut (remote session ended)")
    case .crashed:
      record(false, "Pause test: coordinator → crashed")
    }

    launcher.disconnect(profileID: profile.id)
    for _ in 0..<25 {
      try? await Task.sleep(for: .milliseconds(200))
      if !launcher.isActive(profile.id) { break }
    }
    if let notice = launcher.sessionEndNotice, notice.profileID == profile.id {
      let end = await SessionCoordinator.handleSessionEnd(
        notice: notice,
        duration: notice.durationSeconds,
        store: store,
        launcher: launcher
      )
      store.applySessionOutcome(profileID: profile.id, outcome: end)
      launcher.clearSessionEndNotice(for: profile.id)
    }
    record(!launcher.isActive(profile.id), "Pause test: cleanup disconnect")
    return failures
  }

  /// Close the frontmost sdl-freerdp window via AppleScript (simulates user closing RDP window).
  nonisolated private static func closeFreeRDPWindow() -> Bool {
    let script = """
    tell application "System Events"
      set procs to every process whose name contains "freerdp"
      if (count of procs) is 0 then return "no"
      tell first item of procs
        if (count of windows) is 0 then return "no"
        tell window 1
          perform action "AXPress" of button 1
        end tell
      end tell
    end tell
    return "ok"
    """
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return proc.terminationStatus == 0 && out == "ok"
  }
}
