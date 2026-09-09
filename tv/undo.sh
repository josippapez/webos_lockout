#!/bin/sh
# Reverts everything lockout.sh applied. Leaves Homebrew's own stubs alone.
set -u
MARKER='# --- lg-lockout ---'
CHAIN=LG_LOCKOUT
OPTION_PREFS=/var/luna/preferences/option
IPT=/usr/sbin/iptables
IP6T=/usr/sbin/ip6tables

echo "reverting lg-lockout"
if grep -qF "$MARKER" /etc/hosts 2>/dev/null && grep -q ' /etc/hosts ' /proc/mounts; then
  umount /etc/hosts && echo "  hosts: unmounted" || echo "  hosts: umount FAILED"
else
  echo "  hosts: nothing to unmount"
fi
for tool in "$IPT" "$IP6T"; do
  [ -x "$tool" ] || continue
  while "$tool" -C OUTPUT -j "$CHAIN" 2>/dev/null; do "$tool" -D OUTPUT -j "$CHAIN"; done
  "$tool" -F "$CHAIN" 2>/dev/null && "$tool" -X "$CHAIN" 2>/dev/null && echo "  $(basename "$tool"): $CHAIN removed"
done
if [ -f "${OPTION_PREFS}.lg-lockout.bak" ]; then
  cp "${OPTION_PREFS}.lg-lockout.bak" "$OPTION_PREFS" && sync && echo "  prefs: restored from backup (reboot to apply)"
else
  echo "  prefs: no backup found, left as-is"
fi
echo "remove /var/lib/webosbrew/init.d/20-lg-lockout to stop it running at boot"
