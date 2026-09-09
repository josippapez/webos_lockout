#!/usr/bin/env bash
# Deploys the telemetry lockout to a rooted LG webOS TV over SSH.
# Usage: ./deploy.sh [install|apply|verify|undo|status|logs]
set -euo pipefail

TV="${TV_HOST:-c5}"
REMOTE=/var/lib/webosbrew/lg-lockout
HOOK=/var/lib/webosbrew/init.d/20-lg-lockout
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sshtv() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$TV" "$@"; }

require_tv() {
  if ! sshtv true 2>/dev/null; then
    echo "cannot reach '$TV' over SSH." >&2
    echo "load the key first:  ssh-add --apple-use-keychain ~/.ssh/tv-rooted-c5" >&2
    exit 1
  fi
}

cmd_install() {
  require_tv
  echo "==> installing to $TV:$REMOTE"
  sshtv "mkdir -p $REMOTE"
  scp -q -o BatchMode=yes \
    "$HERE/tv/lockout.sh" "$HERE/tv/verify.sh" "$HERE/tv/undo.sh" "$HERE/tv/sockets.py" \
    "$HERE/domains.txt" "$HERE/ips.txt" \
    "$HERE/wildcard-bases.txt" "$HERE/prefixes.txt" "$HERE/patterns.txt" \
    "$TV:$REMOTE/"
  sshtv "chmod 755 $REMOTE/*.sh && chmod 644 $REMOTE/*.txt"
  echo "==> registering boot hook $HOOK"
  sshtv "ln -sf $REMOTE/lockout.sh $HOOK && ls -l $HOOK"
  echo "==> done. run './deploy.sh apply' to activate now, or reboot."
}

cmd_apply()  { require_tv; echo "==> applying"; sshtv "$REMOTE/lockout.sh"; }
cmd_verify() { require_tv; sshtv "$REMOTE/verify.sh"; }
cmd_undo()   { require_tv; sshtv "$REMOTE/undo.sh"; }
cmd_logs()   { require_tv; sshtv "tail -40 $REMOTE/lockout.log"; }

cmd_status() {
  require_tv
  echo "TV:        $TV ($(sshtv 'cat /etc/starfish-release'))"
  echo "installed: $(sshtv "[ -x $REMOTE/lockout.sh ] && echo yes || echo no")"
  echo "boot hook: $(sshtv "[ -L $HOOK ] && echo yes || echo no")"
  echo "init.d:"; sshtv 'ls -l /var/lib/webosbrew/init.d/' | sed 's/^/  /'
}

case "${1:-install}" in
  install) cmd_install ;;
  apply)   cmd_apply ;;
  verify)  cmd_verify ;;
  undo)    cmd_undo ;;
  status)  cmd_status ;;
  logs)    cmd_logs ;;
  *) echo "usage: $0 [install|apply|verify|undo|status|logs]" >&2; exit 2 ;;
esac
