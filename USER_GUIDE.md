# TailRDP User Guide

## What you need

| Component | Required for | Install |
|-----------|--------------|---------|
| Tailscale | Discovering machines on your tailnet | [tailscale.com/download](https://tailscale.com/download) or `brew install tailscale` |
| FreeRDP (`sdl-freerdp`) | Remote desktop window | `brew install freerdp` |
| SSH key auth | File transfer, Linux session heal | Optional — set up `ssh-copy-id user@host` |

TailRDP does **not** bundle Tailscale or FreeRDP. RDP works without SSH.

**Platform:** macOS 15+, Apple Silicon (arm64) for pre-built artifacts from `./build.sh`.

## First launch

1. **Open the app** — unsigned builds: Finder → right-click `TailRDP.app` → **Open** (first time only; bypasses Gatekeeper).
2. **Setup wizard** walks through:
   - Welcome + what TailRDP needs
   - Tailscale status (skip if you will add hosts manually)
   - FreeRDP status + optional path override
   - **Default username** (required) — applied to new hosts
   - Refresh tailnet and show discovered machine count
3. Re-open the wizard anytime: **Settings → Open setup assistant…**

## Sidebar and hosts

- **All tailnet peers** appear (Linux, Windows, macOS, Android). Only machines with an RDP server can be connected to.
- **Offline machines** are hidden by default. Enable **Settings → Show offline machines in sidebar**.
- **Add Host** (+ toolbar): manual entry when a machine is not on Tailscale or discovery is skipped.
- **Delete Host**: right-click a host → Delete Host.

## Connecting

1. Select a host.
2. **Connection** tab: set display name, address, port, username, and **Save** the password.
   - Passwords are stored in **macOS Keychain** on this Mac only (`app.tailrdp`).
3. Click **Connect**.

If Tailscale reports a host offline but you have a saved address, you can still connect.

## File transfer

**Files** tab: dual-pane SFTP browser. Requires passwordless SSH (`BatchMode`) to the host.
Remote home directory is detected via SSH when possible.

## Linux (gnome-remote-desktop)

Two common setups:

- **Remote Login** (system daemon, NLA) — fresh session; needs `grdctl --system rdp set-credentials`.
- **Desktop Sharing** (user daemon) — mirrors active Wayland session (black screen on X11).

TailRDP can auto-recover stuck Linux sessions when SSH works. If SSH is unavailable, pause/crash banners may say *"SSH unavailable — session state unverified."*

## Troubleshooting

| Issue | Action |
|-------|--------|
| `sdl-freerdp not found` | `brew install freerdp`; set path in Settings |
| Tailscale CLI not found | Install Tailscale app or CLI; set override in Settings |
| Gatekeeper blocks app | Right-click → Open, or System Settings → Privacy & Security |
| Password not accepted | Re-save in Connection tab; check username matches remote account |
| File transfer fails | Verify `ssh user@host` works without a password prompt |

## Profiles and passwords

- Host settings: `~/Library/Application Support/TailRDP/profiles.json`
- Passwords: Keychain per Mac — not portable to another Mac via profile export (deferred feature).
