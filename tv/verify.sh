#!/bin/sh
# Reports the live state of every lockout control. Read-only.
set -u
MARKER='# --- lg-lockout ---'
CHAIN=LG_LOCKOUT
OPTION_PREFS=/var/luna/preferences/option
IPT=/usr/sbin/iptables
fail=0
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; fail=$((fail+1)); }
note() { echo "  ..    $*"; }

echo "webOS telemetry lockout: verification"
echo "$(cat /etc/starfish-release 2>/dev/null)"
echo
echo "[1] hosts blocklist"
if grep -qF "$MARKER" /etc/hosts 2>/dev/null; then
  ok "marker present ($(grep -c '^0\.0\.0\.0 ' /etc/hosts) domains)"
else
  bad "marker absent, hosts blocking not applied"
fi
if grep -q ' /etc/hosts ' /proc/mounts; then ok "/etc/hosts is bind-mounted"; else bad "/etc/hosts not bind-mounted"; fi
for d in lgsmartad.com lgtvcommon.com common.lgthinq.com ngfts.lge.com \
         hr.nextlgsdp.com eu.nextlgsdp.com an.nextlgsdp.com xk.nextlgsdp.com \
         hr.lgsmartad.com hr.lgappstv.com hr.lgtvsdp.com aic.lgtviot.com \
         hr-ad-lgsmartad-com.aws-prd.net aic-ngfts.lge.com \
         alphonso.tv lgads.tv; do
  r=$(getent hosts "$d" 2>/dev/null | head -1 | awk '{print $1}')
  case "$r" in
    0.0.0.0|::1) ok "$d -> $r (blocked)" ;;
    "")          note "$d -> no result (does not resolve upstream)" ;;
    *)           bad "$d -> $r (NOT blocked)" ;;
  esac
done
echo
echo "[2] upload daemon stubs (set by Homebrew startup.sh)"
for p in /tmp/rdxd /tmp/uploadd /var/spool/rdxd /var/spool/uploadd/pending /var/spool/uploadd/uploaded; do
  if grep -qE " $p (tmpfs|.*) ro," /proc/mounts; then ok "$p read-only"; else bad "$p writable"; fi
done
echo
echo "[3] iptables drops for DNS-bypassing IPs"
if [ -x /usr/sbin/ip6tables ] && ! /usr/sbin/ip6tables -L -n >/dev/null 2>&1; then
  note "kernel has no ip6_tables module, IPv4 filtering only (both target IPs are IPv4)"
fi
if "$IPT" -S "$CHAIN" >/dev/null 2>&1; then
  ok "$CHAIN exists with $("$IPT" -S "$CHAIN" | grep -c ' -j DROP') DROP rules"
  "$IPT" -S "$CHAIN" | grep ' -j DROP' | sed 's/^/        /'
else
  bad "$CHAIN missing"
fi
if "$IPT" -C OUTPUT -j "$CHAIN" 2>/dev/null; then ok "OUTPUT jumps to $CHAIN"; else bad "OUTPUT does not jump to $CHAIN"; fi
echo
echo "[4] privacy preferences"
python3 - "$OPTION_PREFS" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"  FAIL  cannot read prefs: {e}"); sys.exit(0)
for k in ("usageCare", "dbgLogUpload", "faultLogUpload"):
    if k not in d:
        print(f"  ..    {k} absent from this firmware")
    elif d[k] is False:
        print(f"  PASS  {k} = false")
    else:
        print(f"  FAIL  {k} = {json.dumps(d[k])}")
PY
echo
echo "[5] EULA consent flags"
python3 - /var/luna/preferences/eula <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1])).get("eulaStatus", {})
except Exception as e:
    print(f"  FAIL  cannot read eula: {e}"); sys.exit(0)
for k in ("acrAllowed","acrOnAllowed","acrGdprAllowed","acrAdAllowed",
          "customAdAllowed","thirdPartySharingAllowed","marketingOnAllowed",
          "voiceAllowed","voice2Allowed","remoteDiagAllowed"):
    if k not in s: print(f"  ..    {k} absent")
    elif s[k] is False: print(f"  PASS  {k} = false")
    else: print(f"  FAIL  {k} = {json.dumps(s[k])}")
PY
echo
echo "[6] telemetry processes still running"
for p in sdx rdxd uploadd admanager iot-client trigger_thinq; do
  if pgrep -x "$p" >/dev/null 2>&1; then note "$p running (egress blocked, process not killed)"; fi
done
echo
echo "[7] external connections, by owning process"
echo "      (an AWS endpoint is usually Netflix or Google FCM, not LG telemetry)"
if [ -x "$(dirname "$0")/sockets.py" ]; then
  python3 "$(dirname "$0")/sockets.py"
else
  netstat -tn 2>/dev/null | awk '/ESTABLISHED/{print $5}' | grep -v '^127\.' | sort -u | sed 's/^/        /'
fi
echo
echo "[8] LG telemetry daemons: external sockets (expect none)"
for p in sdx rdxd uploadd admanager iot-client trigger_thinq; do
  pgrep -x "$p" >/dev/null 2>&1 || continue
  out=$(python3 "$(dirname "$0")/sockets.py" "$p" 1 2>/dev/null | sed 's/^  t+0s  //')
  case "$out" in
    *"no external sockets"*) ok "$out" ;;
    "")                      note "$p: could not read" ;;
    *)                       bad "$out" ;;
  esac
done
echo
if [ "$fail" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: $fail check(s) failed"; fi
exit 0
