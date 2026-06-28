# TailRDP

Native macOS (SwiftUI) RDP client for a Tailscale network. Discover tailnet
machines, tune connection settings, connect, and transfer files — a thin wrapper
around FreeRDP + SSH/SCP.

## Quick start (users)

**Prerequisites** (install separately):

- macOS 15+ on Apple Silicon (arm64)
- [Tailscale](https://tailscale.com/download) — signed in to your tailnet
- FreeRDP — `brew install freerdp` (provides `sdl-freerdp`)
- SSH keys (optional) — for file transfer and Linux session auto-recovery

**First launch:**

1. Build or open `TailRDP.app` (unsigned builds: right-click → **Open** the first time).
2. Complete the setup wizard: verify Tailscale + FreeRDP, set your default username, refresh the tailnet.
3. Select a machine in the sidebar, open **Connection**, save the RDP password (stored in Keychain on this Mac).
4. Click **Connect**.

All tailnet peers appear in the sidebar (Linux, Windows, macOS, Android). Only
hosts running an RDP server can be connected to — see [USER_GUIDE.md](USER_GUIDE.md).

Passwords are stored in the macOS Keychain (`app.tailrdp`) and passed to FreeRDP
via stdin (`/from-stdin:force`), never on the command line.

## Build (developers)

```sh
./build.sh              # arm64 release → TailRDP.app + dist/TailRDP.app
INSTALL=1 ./build.sh    # also copy to /Applications
swift test              # unit tests
swift run TailRDP --verify-session   # session logic smoke test
```

Requires Swift toolchain, macOS 15 SDK.

## Architecture

```
Sources/TailRDP/
  Models/    AppSettings, HostProfile, RDPSettings, SessionHealth, TailscalePeer
  Services/  CredentialStore (Keychain), DependencyChecker, ProcessRunner,
             ProfileStore, RDPLauncher, RemoteDisplayRecovery,
             SessionCoordinator, SFTPService, TailscaleService
  Views/     ContentView, FirstRunWizardView, PeerSidebar, HostDetailView,
             ConnectionSettingsView, FileTransferView, StatusBannerView
  Logic/     SessionEndClassifier
Tests/TailRDPTests/
```

- Profiles: `~/Library/Application Support/TailRDP/profiles.json`
- Passwords: Keychain service `app.tailrdp`, account = profile id
- Bundle ID: `app.tailrdp`

See [HANDOVER.md](HANDOVER.md) for phased implementation notes and deferred items.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
