# TailRPD

Native macOS (SwiftUI) RDP client for a Tailscale network. Discover a tailnet
machine, tune its connection settings, connect, and transfer files — all from
one app. A thin, reliable wrapper around FreeRDP + SSH/SCP.

## Features

- **Discovery** — lists tailnet machines from `tailscale status --json` with live
  online indicators.
- **Per-host settings** — resolution (fixed or dynamic), GFX codec
  (AVC444/AVC420/RFX), color depth, network profile, clipboard, audio,
  auto-reconnect, and a ⌘→Ctrl key remap (so ⌘C/⌘V work over RDP).
- **One-click connect** — launches `sdl-freerdp` with the tuned arguments.
- **File transfer** — dual-pane SFTP browser (push/pull, drag-and-drop from
  Finder) over your existing SSH keys.
- **Secure credentials** — passwords live in the macOS Keychain; passed to
  FreeRDP via `/p:` at launch (Process uses `execve`, so nothing hits the shell
  history; FreeRDP scrubs it from its own process title).

## Build

```sh
./build.sh            # swift build → assemble TailRPD.app → ad-hoc sign → install to /Applications
```

Requires the Swift toolchain, plus `freerdp` and `tailscale` installed
(`brew install freerdp`). macOS 14+.

## Architecture

```
Sources/TailRPD/
  Models/    RDPSettings, TailscalePeer, HostProfile
  Services/  ProcessRunner, KeychainService, TailscaleService,
             RDPLauncher, SFTPService, ProfileStore, AppError
  Views/     ContentView, PeerSidebar, HostDetailView,
             ConnectionSettingsView, FileTransferView
```

- Profiles persist to `~/Library/Application Support/TailRPD/profiles.json`.
- Passwords: Keychain service `com.aegis.rdp`, account = lowercased hostname.

## Notes

Two RDP server models seen on Linux + gnome-remote-desktop:
- **Remote Login** (system daemon, NLA gateway) — fresh independent session;
  best for headless machines. Requires a gateway credential
  (`grdctl --system rdp set-credentials <user> <pass>`).
- **Desktop Sharing** (user daemon) — mirrors the active session; only captures
  a **Wayland** session (black screen on X11).
