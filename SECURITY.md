# Security

TailRDP security model for a **personal / small-team tailnet RDP client**. This is not a hardened enterprise remote-access product.

---

## Summary

| Asset | Protection |
|-------|------------|
| RDP passwords | macOS Keychain (`app.tailrdp`), `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; passed via `/p:` argv at launch |
| Usernames | Plain JSON in Application Support |
| RDP traffic | Tailscale wire + optional NLA; **server cert not verified** (`/cert:ignore`) |
| SSH recovery | Your SSH keys; `BatchMode=yes`, `StrictHostKeyChecking=accept-new` |
| Remote scripts | Bundled, SHA256-pinned; run as SSH user on remote host |

---

## Credentials

### Keychain

- **Service:** `app.tailrdp`
- **Account:** profile `id` (lowercased hostname or manual name)
- **Accessibility:** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — available after first unlock; not synced to other devices
- **Not in:** profile export JSON

### FreeRDP password delivery

Passwords are passed to FreeRDP as `/p:password` in the process argv at launch (briefly visible in process listings). `previewCommand()` shows `••••••` instead of the secret. OSLog argv output is redacted via `AppLog.redactedArgv`.

**In memory:** passwords exist briefly as Swift `String` during launch.

### Legacy migration

One-time import from `~/Library/Application Support/TailRDP/credentials.json` into Keychain, then the JSON file is deleted.

### Profile export

Export contains **no passwords**. Import requires re-entering passwords per host on each Mac.

---

## Network and RDP

### Tailscale

Discovery uses local Tailscale CLI (`tailscale status --json`). Traffic to peers is over the tailnet (WireGuard). TailRDP does not implement its own VPN.

### TLS / certificates

FreeRDP is invoked with **`/cert:ignore`**. RDP server certificates are **not** validated. This is typical for home lab / tailnet hosts with self-signed or rotating certs but is a deliberate trust tradeoff.

**Risk:** susceptible to MITM on the path from Mac to peer if tailnet or host is compromised.

### Authentication

NLA (`/sec:nla`) is always used. Failed auth surfaces as exit code 24 / explicit error strings without auto-heal.

---

## SSH and remote scripts

### SSH usage

| Feature | SSH required |
|---------|--------------|
| File transfer | Yes |
| Linux session inspect/recover | Yes |
| Pause vs logout verification | Yes (Linux) |
| RDP connect | No |

SSH options: `BatchMode=yes`, `ConnectTimeout=10`, `StrictHostKeyChecking=accept-new`.

**Assumption:** passwordless public-key auth. TailRDP does not store SSH passwords.

### Remote script trust

Scripts in `Sources/TailRDP/RemoteScripts/`:

- **`terminate_sessions.sh`** — ends remote Wayland sessions via `loginctl`
- **`recover.sh`** — backs up/removes `~/.config/monitors.xml`, terminates sessions
- **`report.py`** — reads layout, sessions, journal excerpts

Executed as: `ssh user@host '<script>'`.

**Scope:** scripts only affect sessions matching `Remote=yes`, `Type=wayland`, SSH user UID. They do not run as root unless your SSH user has that capability (they should not).

**Integrity:** SHA256 hashes pinned in `RemoteScriptLoader`. Mismatch logs an error and the script is **not** executed.

**Risk:** a compromised remote host could manipulate `loginctl`/journal output seen by TailRDP (confused-deputy on the client side), not inject arbitrary script content if checksum verification succeeds.

---

## Local data

| Path | Contents | Sensitivity |
|------|----------|-------------|
| `~/Library/Application Support/TailRDP/profiles.json` | Hosts, settings, banner state | Medium (usernames, addresses) |
| Keychain | Passwords | High |
| OSLog | Redacted argv; stderr tails | Low–medium |

Protect Mac login and FileVault like any machine storing Keychain secrets.

---

## Threat model (explicit)

### In scope (designed for)

- Single user on a trusted Mac connecting to **their own** tailnet machines
- Casual protection against password exposure in shell history and casual disk reads (passwords are not written to profiles.json)
- Reasonable Linux session recovery without manual SSH for common GNOME RDP issues

### Out of scope (not guaranteed)

- Protection against malware on the Mac with Keychain access while unlocked
- Protection against compromised tailnet peer impersonation without cert verification
- Secure multi-user or shared-machine deployment
- Audited remote execution on hostile servers
- Password portability across machines without re-entry

---

## Reporting issues

For this personal project, open an issue or contact the maintainer directly. Include Console logs filtered to `subsystem:app.tailrdp` and avoid pasting passwords or full stderr with secrets.

---

## Related docs

- [USER_GUIDE.md](USER_GUIDE.md) — passwords, export, SSH setup
- [HANDOVER.md](HANDOVER.md) — architecture and script details
- [CONTRIBUTING.md](CONTRIBUTING.md) — updating script checksums
