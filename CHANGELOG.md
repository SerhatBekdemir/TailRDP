# Changelog

All notable changes to TailRDP. Version **1.0.0** matches `build.sh` / Info.plist.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

---

## [Unreleased]

### Added

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

- Keychain items use `kSecAttrAccessibleWhenUnlocked`
- SSH-unknown banner: “Session ended — couldn't verify remote state”
- Remote scripts extracted from inline strings to `RemoteScripts/`

### Security

- Documented threat model in SECURITY.md
- Passwords remain stdin-only; never in argv or export

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
[1.0.0]: initial distributable milestone
