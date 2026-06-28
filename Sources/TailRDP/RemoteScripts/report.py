import os
import subprocess
import xml.etree.ElementTree as ET

since = os.environ.get("SINCE_MINUTES", "").strip()
layout_parts = []
mon_path = os.path.join(os.path.expanduser("~"), ".config", "monitors.xml")
if os.path.isfile(mon_path):
    try:
        root = ET.parse(mon_path).getroot()
        for cfg in root.findall("configuration"):
            for logical in cfg.findall("logicalmonitor"):
                scale_el = logical.find("scale")
                scale = float(scale_el.text) if scale_el is not None and scale_el.text else 1.0
                connectors = [
                    m.find("connector").text
                    for m in logical.findall("monitor")
                    if m.find("connector") is not None and m.find("connector").text
                ]
                mode = logical.find(".//mode")
                wh = ""
                if mode is not None:
                    w, h = mode.find("width"), mode.find("height")
                    if w is not None and h is not None and w.text and h.text:
                        wh = f" {w.text}x{h.text}"
                names = ",".join(connectors) if connectors else "remote"
                layout_parts.append(f"{names}{wh} @{scale:g}x")
    except Exception as e:
        layout_parts.append(f"monitors.xml: {e}")
else:
    layout_parts.append("default layout")

uid = os.getuid()
remote_ids = []
try:
    out = subprocess.check_output(["loginctl", "list-sessions", "--no-legend"], text=True)
    for line in out.splitlines():
        parts = line.split()
        if not parts:
            continue
        sid = parts[0]
        show = subprocess.check_output(
            ["loginctl", "show-session", sid, "-p", "Remote", "-p", "Type", "-p", "User"],
            text=True,
        )
        fields = dict(ln.split("=", 1) for ln in show.splitlines() if "=" in ln)
        if fields.get("Remote") == "yes" and fields.get("Type") == "wayland":
            if fields.get("User", "").strip() == str(uid):
                remote_ids.append(sid)
except Exception:
    pass

errors = []
if since:
    journal_args = ["journalctl", "--user", "-n", "60", "--no-pager", f"--since={since} min ago"]
    system_args = ["journalctl", "-n", "80", "--no-pager", f"--since={since} min ago"]

    def collect(args, keywords):
        try:
            out = subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                s = line.strip()
                if not s or s.startswith("-- "):
                    continue
                if keywords and not any(k in s for k in keywords):
                    continue
                errors.append(s[-240:])
        except Exception:
            pass

    collect(journal_args, ("ERROR", "ERR", "SEGV", "failed", "crash", "RDP"))
    collect(system_args, ("gnome-shell", "gnome-remote-de", "SEGV", "RDP server"))

print(f"__REPORT__layout={' | '.join(layout_parts) if layout_parts else 'none'}")
print(f"__REPORT__sessions={','.join(remote_ids)}")
print("__REPORT__errors=" + "|||".join(errors[-8:]))
