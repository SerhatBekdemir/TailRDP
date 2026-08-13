# TailRDP

Native macOS (SwiftUI) RDP client for [Tailscale](https://tailscale.com) tailnets. Discover machines on your tailnet, tune per-host connection settings, connect via FreeRDP, transfer files over SSH, and manage Linux GNOME remote-desktop sessions intelligently.

**Bundle ID:** `app.tailrdp` · **Platform:** macOS 15+, Apple Silicon (arm64) · **License:** [Apache 2.0](LICENSE)

---

## Documentation

| Document | Audience | Contents |
|----------|----------|----------|
| [USER_GUIDE.md](USER_GUIDE.md) | Users | Install, connect, file transfer, Linux sessions, troubleshooting |
| [HANDOVER.md](HANDOVER.md) | Developers | Architecture, session lifecycle, key files, verify commands |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Contributors | Build, test, CI, remote scripts, conventions |
| [SECURITY.md](SECURITY.md) | Everyone | Credentials, threat model, remote script trust |
| [CHANGELOG.md](CHANGELOG.md) | Everyone | Release and milestone history |

---

## Quick start

### Prerequisites

| Component | Purpose | Install |
|-----------|---------|---------|
| macOS 15+ (arm64) | Host OS | — |
| [Tailscale](https://tailscale.com/download) | Tailnet discovery | App or `brew install tailscale` |
| FreeRDP | RDP client (`sdl-freerdp`) | `brew install freerdp` |
| SSH keys (optional) | File transfer, Linux auto-recovery | `ssh-copy-id user@host` |

TailRDP does **not** bundle Tailscale or FreeRDP.

### Build and run

```sh
./build.sh                    # release build → dist/TailRDP-1.0.2.app
INSTALL=1 ./build.sh          # also install to /Applications
swift run TailRDP               # debug run from source
swift run TailRDP --verify-session   # session logic smoke test (no UI)
```

**First launch:** unsigned builds require Finder → right-click `dist/TailRDP-1.0.2.app` → **Open** once.

**Release versioning:** small/minor changes use the patch increment (for example `1.0.1`), medium changes use the middle increment (`1.1.0`), and major changes use the first increment (`2.0.0`). Set `TAILRDP_VERSION=...` to override the current release version for a build. Set `TAILRDP_ICON_PATH=Resources/AppIcon-QA.icns` when producing a white-icon QA copy.

**First use:** complete the setup wizard (Tailscale + FreeRDP check, default username, tailnet refresh), select a host, save the RDP password in the **Connection** tab, click **Connect**.

Passwords are saved in `~/Library/Application Support/TailRDP/credentials.json` on this Mac and passed to FreeRDP via `/p:` at launch — not stored in profile export JSON. See [SECURITY.md](SECURITY.md).

---

## Features (summary)

- **Tailnet discovery** — all peers except self; manual host add/delete
- **Offline connect** — use saved address when Tailscale reports offline
- **Per-host settings** — resolution, codec, network profile, clipboard, smart reconnect
- **Session semantics** — pause vs logout vs crash; sticky and flash banners
- **Linux GNOME recovery** — SSH scripts for stuck Wayland sessions, adaptive resume delay
- **File transfer** — SFTP browser with remote `$HOME` detection
- **Cert pinning** — trust-on-first-use (`/cert:tofu`); prompt on server cert change
- **Profile export/import** — settings JSON (passwords re-entered after import)
- **Structured logging** — OSLog subsystem `app.tailrdp` (Console.app)

---

## Project layout

```
Sources/TailRDP/
  Models/         HostProfile, RDPSettings, SessionHealth, ProfileExport, …
  Services/       ProfileStore, RDPLauncher, SessionCoordinator,
                  RemoteDisplayRecovery, RemoteScriptLoader, CredentialStore,
                  TailscaleService, SFTPService, AppLog, …
  Views/          SwiftUI (ContentView, HostDetailView, …)
  Logic/          SessionEndClassifier (pure, testable)
  RemoteScripts/  Pinned SSH scripts (terminate, recover, report)
Tests/TailRDPTests/
.github/workflows/ci.yml
build.sh
Resources/        App icon assets
```

**On disk (runtime):**

- Profiles: `~/Library/Application Support/TailRDP/profiles.json`
- Passwords: `~/Library/Application Support/TailRDP/credentials.json` (profile `id` as key)

---

## Verify (developers)

```sh
swift build
swift test                        # requires full Xcode
swift run TailRDP --verify-session
./build.sh                        # includes --verify-session gate
```

CI (when pushed to GitHub): build, test, and `--verify-session` on `macos-15`. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

## License

Apache License 2.0 — see [LICENSE](LICENSE).
