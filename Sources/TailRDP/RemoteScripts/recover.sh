set -e
MON="$HOME/.config/monitors.xml"
BACKUP="none"
if [ -f "$MON" ]; then
  BACKUP="$MON.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$MON" "$BACKUP"
  rm -f "$MON"
fi
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
TERMINATED=0
for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  [ -n "$sid" ] || continue
  remote=$(loginctl show-session "$sid" -p Remote --value 2>/dev/null)
  type=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
  user=$(loginctl show-session "$sid" -p User --value 2>/dev/null)
  if [ "$remote" = yes ] && [ "$type" = wayland ] && [ "$user" = "$(id -u)" ]; then
    if loginctl terminate-session "$sid" 2>/dev/null; then
      TERMINATED=$((TERMINATED+1))
    fi
  fi
done
echo "__RECOVER__ok=1"
echo "__RECOVER__backup=$BACKUP"
echo "__RECOVER__terminated=$TERMINATED"
