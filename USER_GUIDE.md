# TailRDP User Guide

Complete guide for using TailRDP on your Mac to connect to machines on a Tailscale tailnet via RDP.

---

## Table of contents

1. [Requirements](#requirements)
2. [Installation](#installation)
3. [First launch](#first-launch)
4. [Main window](#main-window)
5. [Connecting](#connecting)
6. [Session banners](#session-banners)
7. [Connection settings](#connection-settings)
8. [File transfer](#file-transfer)
9. [Linux (GNOME Remote Desktop)](#linux-gnome-remote-desktop)
10. [Settings](#settings)
11. [Profiles and passwords](#profiles-and-passwords)
12. [Troubleshooting](#troubleshooting)
13. [Limitations](#limitations)

---

## Requirements

| Component | Required for | How to get it |
|-----------|--------------|---------------|
| **macOS 15+** (Apple Silicon) | Running TailRDP | Pre-built `./build.sh` output is arm64-only |
| **Tailscale** | Discovering tailnet machines | [tailscale.com/download](https://tailscale.com/download) or Homebrew |
| **FreeRDP** (`sdl-freerdp`) | The remote desktop window | `brew install freerdp` |
| **SSH key auth** | File transfer, Linux session heal | Optional — `ssh-copy-id user@host` |

TailRDP is a thin wrapper: it launches `tailscale`, `sdl-freerdp`, and optionally `ssh`/`scp`. Nothing is bundled inside the app.

**RDP without SSH works.** You can connect to Windows or Linux hosts without SSH; you lose file transfer and Linux auto-recovery.

---

## Installation

### From source (typical)

```sh
git clone <your-repo> TailRDP && cd TailRDP
./build.sh
# App is at TailRDP.app and dist/TailRDP.app
INSTALL=1 ./build.sh   # copies to /Applications
```

### Gatekeeper (unsigned builds)

TailRDP is ad-hoc signed, not notarized. On first open:

1. Finder → right-click `TailRDP.app` → **Open**, confirm **Open** in the dialog, **or**
2. System Settings → Privacy & Security → allow TailRDP

---

## First launch

The **setup wizard** runs automatically (re-open anytime via **Settings → Open setup assistant…**):

| Step | What it checks |
|------|----------------|
| Welcome | Overview of dependencies |
| Tailscale | CLI/app found; optional path override |
| FreeRDP | `sdl-freerdp` found; optional path override |
| Username | **Required** — default RDP + SSH username for new hosts |
| Tailnet | Refresh peer list; show machine count |

If FreeRDP or Tailscale is missing, a red banner appears at the top of the main window with a link to **Settings**.

---

## Main window

### Sidebar

- Lists tailnet peers (Linux, Windows, macOS, Android). Only hosts **with an RDP server** can actually be connected to.
- **Green dot** — online on Tailscale.
- **Offline hosts** — hidden by default; enable in Settings.
- **Toolbar +** — add a manual host (name, address, OS, port).
- **Right-click** — delete host.
- Icons indicate active session, paused session, or error state.

### Detail area

Two tabs per host:

- **Connection** — credentials, display settings, advanced recovery tools.
- **Files** — SFTP file browser (requires SSH).

### Bottom banner

Status strip for the selected host: success (green), paused (blue), error (red). See [Session banners](#session-banners).

---

## Connecting

1. Select a host in the sidebar.
2. Open **Connection** → enter username → enter password → **Save**.
   - Password is stored in **macOS Keychain** on this Mac only.
3. Click **Connect** (or **Resume** / **Reconnect** if a sticky banner is showing).

### Offline connect

If Tailscale reports a host offline but you have a **saved address**, Connect still works. A wifi-slash icon indicates offline mode; help text explains you are using the saved address.

### Multiple Linux remote sessions

When resuming a paused Linux session, if SSH detects **more than one** active remote Wayland session, a sheet lets you pick which session to keep. Others are ended before reconnect.

---

## Session banners

TailRDP distinguishes how an RDP session ended and shows appropriate actions.

| End type | Meaning | Banner | Actions |
|----------|---------|--------|---------|
| **Paused** | You closed the RDP window; remote session may still run | Blue sticky | **Resume**, **Disconnect** (Linux: ends remote session via SSH) |
| **Logged out** | You clicked Disconnect or remote logged out | Green flash (auto-dismiss ~5s) | — |
| **Crashed** | Unexpected failure | Red sticky | **Reconnect**; may auto-heal on Linux |
| **SSH unverified** | Session ended but SSH could not confirm remote state | Blue sticky, special message | **Resume** with caution |

**Flash banners** (green success messages) fade away after about five seconds. **Sticky banners** persist when you switch hosts until you resume, reconnect, disconnect, or dismiss.

### Linux note

FreeRDP’s built-in auto-reconnect is **disabled for Linux hosts** because it causes black-screen stalls with GNOME Remote Desktop after pause.

---

## Connection settings

### Basic

- **Display name**, **address**, **port** (default 3389)
- **Username** and **password** (Keychain)
- **Resolution** — fixed or dynamic
- **Codec** — AVC444, AVC420, RemoteFX, progressive
- **Network profile** — LAN, broadband, WAN, auto (maps to FreeRDP `/network:`)
- **Clipboard**, **sound**, **⌘→Ctrl** remapping
- **Auto-reconnect** (FreeRDP; not used on Linux)
- **Smart reconnect** — after crashes only, run Linux SSH recovery (never on pause/logout)

### Last good settings

If a session runs successfully for ~45 seconds, its settings are saved as **last good**. The next Connect uses those unless you change settings or a crash triggers safe fallback.

After repeated failures, TailRDP may connect with **safe fallback** (1920×1080, AVC420, 16 bpp, LAN) until a session succeeds.

### Advanced (Linux)

- **Inspect remote session** — layout, active sessions, recent journal errors (SSH).
- **Reset remote desktop** — backup/remove `monitors.xml`, terminate stuck Wayland sessions.
- **Use current settings on next connect** — promote form values to last-good snapshot.

---

## File transfer

**Files** tab: dual-pane browser (local ↔ remote).

**Requires:** passwordless SSH to the host (`ssh user@host` without a password prompt).

- **Home** button uses remote `$HOME` detected via SSH (`echo`/`cd ~`).
- Upload/download via SCP over the tailnet.
- Last remote directory is remembered per host.

---

## Linux (GNOME Remote Desktop)

Two common setups on Linux:

| Mode | Behavior | Credentials |
|------|----------|-------------|
| **Remote Login** | Fresh session at login screen (NLA) | `grdctl --system rdp set-credentials` |
| **Desktop Sharing** | Mirrors active Wayland session | User session; X11 often black screen |

### Pause and resume

Closing the RDP window on your Mac **pauses** (does not log out) the remote session when GNOME keeps it alive. Click **Resume** to reconnect.

TailRDP waits an **adaptive pause** (1.5–8 seconds, default 3s) before Linux resume connects, so the prior RDP socket can tear down. The delay adjusts based on success or failure of past resume attempts.

### Auto-recovery (SSH required)

After a **crash** (not pause/logout), with **Smart reconnect** enabled:

- Clears stuck remote Wayland sessions
- Resets `monitors.xml` after display layout crashes (SEGV in journal)
- Switches to safe client settings after repeated failures

Recovery scripts run over SSH and are pinned by checksum in the app bundle. See [SECURITY.md](SECURITY.md).

### SSH unavailable

If SSH fails, pause/crash handling falls back to classifier-only behavior. The banner shows **“Session ended — couldn't verify remote state”** with guidance that the remote session may still be running.

---

## Settings

Open via **TailRDP → Settings** (or ⌘,).

| Section | Options |
|---------|---------|
| **Setup assistant** | Re-run first-run wizard |
| **Tailscale CLI** | Detected path, override, effective path |
| **FreeRDP** | Detected path, override |
| **Tailnet** | This machine, online count, show offline, refresh |
| **New machines** | Default username for discovered hosts |
| **SSH** | Whether `/usr/bin/ssh` exists |
| **Profiles** | **Export…** / **Import…** JSON (no passwords) |

---

## Profiles and passwords

### Where data lives

| Data | Location |
|------|----------|
| Host profiles (settings, banners, health) | `~/Library/Application Support/TailRDP/profiles.json` |
| RDP passwords | macOS Keychain, service `app.tailrdp`, account = profile id |
| Usernames | In `profiles.json` (not Keychain) |

Passwords are **bound to this Mac and bundle ID**. They do not travel with profile export.

### Export and import

**Settings → Profiles → Export…** saves a JSON file with all host settings (no secrets).

**Import…** merges by host id. After import, re-enter passwords in each host’s **Connection** tab. The import summary lists hosts that need passwords.

---

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `sdl-freerdp not found` | `brew install freerdp`; set path in Settings |
| Tailscale CLI not found | Install Tailscale app; set override in Settings |
| Red dependency banner at top | Open Settings; fix paths or install deps |
| Gatekeeper blocks app | Right-click → Open; or Privacy & Security |
| Password not accepted | Re-save password; verify username; check NLA on server |
| Black screen after resume (Linux) | Wait and retry; Disconnect remote session; Advanced → Reset |
| File transfer fails | Test `ssh user@host` without password prompt |
| “Couldn't verify remote state” | Set up SSH keys; or connect anyway with Resume if you know session is up |
| Stuck on “Resuming…” | Linux socket delay; if persistent, Disconnect remote session |

### Debug logging

Open **Console.app**, filter subsystem **`app.tailrdp`**. Categories: `tailscale`, `rdp`, `ssh`, `session`. Useful when reporting bugs to developers.

---

## Limitations

- **macOS 15+, arm64 only** in current build script.
- **Unsigned / not notarized** — manual trust on first launch.
- **Windows paused disconnect** — Disconnect clears local state; remote session may keep running (no WinRM).
- **`/cert:ignore`** — RDP server certificates are not verified (typical for tailnet/home use).
- **No menu bar agent** — standard windowed app only.
- **No live connection quality metrics** — network profile is static, not measured from session.

See [HANDOVER.md](HANDOVER.md) for planned/deferred improvements.
