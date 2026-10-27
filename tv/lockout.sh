#!/bin/sh
# LG webOS telemetry lockout. Runs at boot from /var/lib/webosbrew/init.d.
# Idempotent: safe to run repeatedly.

set -u

INSTALL_DIR=/var/lib/webosbrew/lg-lockout
LOG="$INSTALL_DIR/lockout.log"
HOSTS_SRC="$INSTALL_DIR/domains.txt"
WILDCARD_SRC="$INSTALL_DIR/wildcard-bases.txt"
PREFIX_SRC="$INSTALL_DIR/prefixes.txt"
PATTERN_SRC="$INSTALL_DIR/patterns.txt"
IPS_SRC="$INSTALL_DIR/ips.txt"
HOSTS_BUILD=/tmp/lg-lockout-hosts
MARKER='# --- lg-lockout ---'
CHAIN=LG_LOCKOUT
OPTION_PREFS=/var/luna/preferences/option
IPT=/usr/sbin/iptables
IP6T=/usr/sbin/ip6tables

# Note the trailing `:` — without it the failed `[ -t 1 ]` test becomes the
# function's exit status, and the script's last log call would make run-parts
# record a failure at every boot.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; if [ -t 1 ]; then echo "$*"; fi; :; }

mkdir -p "$INSTALL_DIR"
log "=== lockout start (pid $$) ==="

# --- Stage 1: /etc/hosts bind-mount -------------------------------------
# nsswitch.conf on this firmware is "hosts:files ... dns", so getaddrinfo
# consults /etc/hosts before DNS. Verified: a bind-mounted entry makes
# lgsmartad.com resolve to ::1 instead of 165.244.150.53.
stage_hosts() {
  if grep -qF "$MARKER" /etc/hosts 2>/dev/null; then
    log "hosts: already applied, skipping"
    return 0
  fi
  if [ ! -f "$HOSTS_SRC" ]; then
    log "hosts: ERROR $HOSTS_SRC missing, skipping stage"
    return 1
  fi

  cp /etc/hosts "$HOSTS_BUILD" || { log "hosts: ERROR cannot copy /etc/hosts"; return 1; }
  {
    echo ''
    echo "$MARKER"
    echo "# Regenerated at boot. Do not edit; edit $HOSTS_SRC instead."
    sed -e 's/#.*//' -e 's/[[:space:]]//g' "$HOSTS_SRC" | while read -r d; do
      [ -n "$d" ] || continue
      echo "0.0.0.0 $d"
      echo "::1 $d"
    done

    # Expand wildcard bases against the prefix list. A hosts file cannot
    # wildcard, and sdx builds its endpoint as <region>.<base> at runtime
    # (HR -> hr.nextlgsdp.com), so the bare base alone is not enough.
    if [ -f "$WILDCARD_SRC" ] && [ -f "$PREFIX_SRC" ]; then
      echo "# expanded from wildcard-bases.txt x prefixes.txt"
      sed -e 's/#.*//' -e 's/[[:space:]]//g' "$WILDCARD_SRC" | while read -r base; do
        [ -n "$base" ] || continue
        echo "0.0.0.0 $base"
        echo "::1 $base"
        sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PREFIX_SRC" | while read -r pre; do
          [ -n "$pre" ] || continue
          echo "0.0.0.0 $pre.$base"
          echo "::1 $pre.$base"
        done
      done
    fi

    # Expand hostname templates. LG encodes the region inside the label for
    # some endpoints (hr-ad-lgsmartad-com.aws-prd.net), which a base+prefix
    # pair cannot express.
    if [ -f "$PATTERN_SRC" ] && [ -f "$PREFIX_SRC" ]; then
      echo "# expanded from patterns.txt x prefixes.txt"
      sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PATTERN_SRC" | while read -r tpl; do
        [ -n "$tpl" ] || continue
        sed -e 's/#.*//' -e 's/[[:space:]]//g' "$PREFIX_SRC" | while read -r pre; do
          [ -n "$pre" ] || continue
          h=$(echo "$tpl" | sed "s/{p}/$pre/g")
          echo "0.0.0.0 $h"
          echo "::1 $h"
        done
      done
    fi
  } >> "$HOSTS_BUILD"

  count=$(grep -c '^0\.0\.0\.0 ' "$HOSTS_BUILD")
  if mount --bind "$HOSTS_BUILD" /etc/hosts; then
    log "hosts: bind-mounted, $count domains blocked"
  else
    log "hosts: ERROR bind-mount failed"
    return 1
  fi
}

# --- Stage 2: iptables drops for hardcoded IPs --------------------------
# These bypass DNS, so hosts entries cannot reach them.
stage_iptables() {
  [ -x "$IPT" ] || { log "iptables: ERROR $IPT not executable"; return 1; }
  [ -f "$IPS_SRC" ] || { log "iptables: ERROR $IPS_SRC missing"; return 1; }

  # This firmware's kernel (5.4.268-329.ptl4tv.5) ships no ip6_tables module,
  # so ip6tables cannot initialise a filter table. Both hardcoded LG endpoints
  # are IPv4, so nothing is lost; probe rather than spew modprobe errors.
  have_ip6=0
  if [ -x "$IP6T" ] && "$IP6T" -L -n >/dev/null 2>&1; then have_ip6=1; fi
  [ "$have_ip6" -eq 1 ] || log "iptables: no IPv6 filter table on this kernel, IPv4 only"

  for tool in "$IPT" "$IP6T"; do
    [ "$tool" = "$IP6T" ] && [ "$have_ip6" -eq 0 ] && continue
    [ -x "$tool" ] || continue
    "$tool" -N "$CHAIN" 2>/dev/null
    "$tool" -F "$CHAIN" 2>/dev/null
    "$tool" -C OUTPUT -j "$CHAIN" 2>/dev/null || "$tool" -I OUTPUT 1 -j "$CHAIN"
  done

  n=0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$IPS_SRC" | while read -r ip; do
    [ -n "$ip" ] || continue
    case "$ip" in
      *:*) [ "$have_ip6" -eq 1 ] && "$IP6T" -A "$CHAIN" -d "$ip" -j DROP 2>/dev/null ;;
      *)   "$IPT"  -A "$CHAIN" -d "$ip" -j DROP 2>/dev/null ;;
    esac
  done
  n=$("$IPT" -S "$CHAIN" 2>/dev/null | grep -c ' -j DROP')
  log "iptables: $CHAIN active with $n DROP rules"
}

# --- Stage 3: privacy preferences ---------------------------------------
# luna-send returns no output over SSH (no /run/luna-service2 socket), so the
# pref file is edited directly. At boot this lands before settingsservice
# reads it. Run manually and a reboot is needed for it to stick.
stage_prefs() {
  [ -f "$OPTION_PREFS" ] || { log "prefs: ERROR $OPTION_PREFS missing"; return 1; }
  [ -f "${OPTION_PREFS}.lg-lockout.bak" ] || cp "$OPTION_PREFS" "${OPTION_PREFS}.lg-lockout.bak"

  python3 - "$OPTION_PREFS" <<'PY' 2>&1 | while read -r l; do log "prefs: $l"; done
import json, sys
path = sys.argv[1]
# Voice consent is NOT here: it lives in /var/luna/preferences/eula as
# voiceAllowed / voice2Allowed (both already false). The "voice" key under
# inputDevicesSupportStatus is a remote-hardware capability flag, not consent,
# so it is deliberately left alone.
want = {"usageCare": False, "dbgLogUpload": False, "faultLogUpload": False}
try:
    with open(path) as f:
        d = json.load(f)
except Exception as e:
    print(f"ERROR unreadable: {e}")
    sys.exit(1)
changed = []
for k, v in want.items():
    if k in d and d[k] != v:
        d[k] = v
        changed.append(k)
if changed:
    tmp = path + ".lg-lockout.tmp"
    with open(tmp, "w") as f:
        json.dump(d, f, separators=(",", ":"))
    import os
    os.replace(tmp, path)
    print("set false: " + ", ".join(sorted(changed)))
else:
    print("already correct, no change")
PY
  sync
}

# --- Stage 4: tracking, log and suggestion daemons -----------------------
# Same set as cleanyourtv-WebOS's debloat minus its "ads" group: its
# scripts/undo-home.sh notes LG's own Home fails to start without admanager and
# adoverlay-service. Nothing Requires= these units (only boot targets want them).
# A no-op stub is bind-mounted over each binary (RAM only, gone at reboot), so
# anything that starts one later (a boot target that runs after this hook, or
# ls-hubd for the on-demand luna services acr2 and sportsalarm) gets a clean
# exit 0, which Restart=on-failure leaves alone. `systemctl mask --runtime`
# does not work here: the units live in /etc/systemd/system, which outranks /run.
DAEMON_UNITS="remotelogger service-logger contentminer nudge"
DAEMON_BINS="$DAEMON_UNITS acr2 sportsalarm"
stage_daemons() {
  printf '#!/bin/sh\nexit 0\n' > "$INSTALL_DIR/stub-noop" && chmod 755 "$INSTALL_DIR/stub-noop"
  for b in $DAEMON_BINS; do
    [ -e "/usr/sbin/$b" ] || continue
    grep -q " /usr/sbin/$b " /proc/mounts || mount --bind "$INSTALL_DIR/stub-noop" "/usr/sbin/$b"
  done
  for u in $DAEMON_UNITS; do systemctl --no-block stop "$u.service" >/dev/null 2>&1; done
  for b in $DAEMON_BINS; do pkill -9 -f "^/usr/sbin/$b"; done
  log "daemons: stubbed $DAEMON_BINS"
}

stage_hosts
stage_iptables
stage_prefs
stage_daemons

log "=== lockout done ==="
