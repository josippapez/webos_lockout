#!/usr/bin/env bash
# Brute-forces the two-letter region prefix space against an LG base domain and
# reports any live prefix missing from prefixes.txt.
#
# LG provisions a separate endpoint per region (hr.nextlgsdp.com etc.) and a
# hosts file cannot wildcard, so new regions have to be detected rather than
# assumed. Measured 2026-09-09: 253 of 676 combinations resolve.
set -euo pipefail
BASE="${1:-nextlgsdp.com}"
RESOLVER="${RESOLVER:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIGARGS=(+short +time=2 +tries=2)
[ -n "$RESOLVER" ] && DIGARGS+=("@$RESOLVER")

echo "scanning 676 two-letter prefixes against $BASE ..."
python3 -c 'import string
for a in string.ascii_lowercase:
    for b in string.ascii_lowercase: print(a+b)' \
  | xargs -P 50 -n 1 -I{} sh -c \
      "a=\$(dig ${DIGARGS[*]} {}.$BASE A 2>/dev/null | grep -E '^[0-9]' | head -1); [ -n \"\$a\" ] && echo {}" \
  2>/dev/null | sort -u > /tmp/live-prefixes.txt

live=$(wc -l < /tmp/live-prefixes.txt | tr -d ' ')
grep -vE '^\s*(#|$)' "$HERE/prefixes.txt" | sort -u > /tmp/known-prefixes.txt
missing=$(comm -23 /tmp/live-prefixes.txt /tmp/known-prefixes.txt)

echo "live prefixes: $live"
if [ -z "$missing" ]; then
  echo "RESULT: prefixes.txt covers every live prefix"
else
  echo "RESULT: live but NOT in prefixes.txt:"
  echo "$missing" | sed 's/^/  /'
  echo "add them to prefixes.txt, then ./deploy.sh install && ./deploy.sh apply"
  exit 1
fi
