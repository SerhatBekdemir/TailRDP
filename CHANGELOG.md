# Changelog

All notable changes to TailRDP. Version **1.0.2** matches `build.sh` / Info.plist.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

---

## [1.0.2] — 2026-08-13

- Surface Tailscale's backend state: a stopped or signed-out tailnet now reports why instead of listing cached peers as online and failing at connect.
- Wait for a Linux host to bring its login screen back before reconnecting after a session is force-ended or healed, so the gnome-remote-desktop handover cannot land mid-respawn and leave a black window.

---

## [1.0.1] — 2026-07-31

- Matrix-green main application icon; preserved the original white icon for QA builds.
- Versioned app artifacts and installation names now use the release version (`TailRDP-1.0.1.app`).
- Documented patch, medium, and major version increments and build-time overrides.

---

## [Unreleased]

### Added

- RDP server certificate pinning via `/cert:tofu` — pinned on first connect, FreeRDP prompt on change (was `/cert:ignore`)
- `TAILRDP_DATA_DIR` env override for profiles/credentials location (sandboxed QA runs; skips Keychain migration)
- `--qa-integration <match>` live tailnet smoke runner
- Duplicate manual-host display names rejected (case-insensitive)
- GitHub Actions CI (build, test, `--verify-session`)
- OSLog subsystem `app.tailrdp` with categories: tailscale, rdp, ssh, session
- Bundled remote scripts with SHA256 pinning (`RemoteScriptLoader`)
- Adaptive Linux resume delay (`SessionHealth.linuxResumeDelayMs`)
- Profile export/import in Settings (JSON, passwords excluded)
- Wayland session picker when multiple remote sessions on Linux resume
- Launch dependency warning banner (missing FreeRDP/Tailscale)
- Flash banner auto-dismiss (5s) for success messages
- Expanded unit tests (recovery matrix, argv, export, script hashes)
- `Sendable` on core value-type models
- Documentation set: SECURITY, CONTRIBUTING, CHANGELOG; expanded README, USER_GUIDE, HANDOVER
- `.gitignore` for `.cursor/`, `dist/`, build artifacts

### Changed

- Audio uses FreeRDP `/sound`; Connection settings now provide a persisted editable full launch-command override with password redaction and validation.
- Sidebar shows only desktop RDP candidates (linux/windows/macos/other); non-candidates dropped on load/merge
- Launch-command preview and host header now reflect actual launch settings under safe fallback (`HostProfile.connectSettings`)
- Profile saves debounced; remote scripts and dependency probes cached; session-end SSH and disk writes deduped
- Setup wizard cannot be dismissed before Finish
- Passwords stored in `credentials.json` (mode 0600); Keychain used only for one-time import of legacy items
- SSH-unknown banner: “Session ended — couldn't verify remote state”
- Remote scripts extracted from inline strings to `RemoteScripts/`

### Fixed

- SIGPIPE crash when writing stdin to a fast-exiting child process
- `ProcessRunner` pipe deadlock (stdout/stderr now drained concurrently)

### Security

- Documented threat model in SECURITY.md
- Passwords passed to FreeRDP via `/p:` argv at launch; redacted in logs and command preview. `/from-stdin` evaluated and rejected (FreeRDP needs a tty) — see SECURITY.md
- Server certificates pinned trust-on-first-use (`/cert:tofu`)

---

## [1.0.0] — 2025-06

Distribution-ready personal tailnet RDP client (`app.tailrdp`).

### Added

- Tailscale peer discovery and profile merge
- FreeRDP launcher with per-host settings and last-good snapshots
- Keychain password storage + `/from-stdin:force`
- Linux GNOME session recovery over SSH
- Session pause / logout / crash classification and sticky banners
- File transfer (SFTP/SCP)
- First-run wizard, Settings, About window
- Offline connect with saved address
- Remote `$HOME` detection for file browser
- `--verify-session` smoke test and XCTest target
- App icon (Tailscale-style dot grid)
- Apache 2.0 license

### Fixed

- Session reconnect races (generation counters, orphan pkill, Linux delay)
- MainActor blocking moved off SSH paths
- RDP stdin password delivery after Keychain migration
- Linux pause/resume banners and reconnect stall
- Tailscale discovery from GUI apps (CLI environment)

---

## Earlier history

| Commit area | Summary |
|-------------|---------|
| Smart session UX | Per-host sticky banners, session health |
| GNOME layout recovery | Auto-detect/reset monitors.xml over SSH |
| Rename TailRDP | File-based credentials → Keychain migration path |
| Initial TailRPD | Native SwiftUI Tailscale RDP client |

See `git log --oneline` for full history.

[Unreleased]: compare with latest tag when releases begin
[1.0.2]: tailnet state reporting and Linux handover settle wait
[1.0.1]: versioned Matrix-green icon release
[1.0.0]: initial distributable milestone
