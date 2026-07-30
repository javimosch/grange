#!/usr/bin/env bash
# Poll /ready and tell a human when it fails.
#
# The external monitor polls /health, which reports "up" the moment the accept
# loop is running — so it stays green through a read-only data directory, a
# backup job that stopped weeks ago, or RSS about to trip the watchdog. Those are
# precisely the failures that rot silently.
#
# /ready answers them but needs a token (it reports operational detail: RSS,
# version, collection count, backup age — not something to publish on a paid
# multi-tenant service). So this runs on the host, where the token already is.
#
# Alerting only on TRANSITIONS: a check that messages every 15 minutes while
# something is wrong trains the recipient to mute it, which is worse than not
# alerting at all. It also reports RECOVERY, so nobody is left wondering.
#
#   readycheck.sh --url http://127.0.0.1:8801 --token "$GRANGE_TOKEN" [--state /var/tmp/grange-ready.state]
set -u
URL="http://127.0.0.1:8801"
TOKEN="${GRANGE_TOKEN:-}"
STATE="/var/tmp/grange-ready.state"
TG_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TG_CHAT="${TELEGRAM_CHAT_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --token) TOKEN="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    --tg-token) TG_TOKEN="$2"; shift 2 ;;
    --tg-chat) TG_CHAT="$2"; shift 2 ;;
    *) echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
  esac
done

BODY=$(curl -s -m 15 -w '\n%{http_code}' "$URL/ready" -H "authorization: Bearer $TOKEN" 2>/dev/null)
CODE=$(printf '%s' "$BODY" | tail -1)
JSON=$(printf '%s' "$BODY" | sed '$d')

if [ "$CODE" = "200" ]; then
  NOW="ok"
  DETAIL="ready"
elif [ -z "$CODE" ] || [ "$CODE" = "000" ]; then
  # unreachable is a DIFFERENT failure from not-ready, and conflating them sends
  # a misleading alert: one means the process is gone, the other that it is sick
  NOW="down"
  DETAIL="no response from $URL/ready"
else
  NOW="failing"
  DETAIL=$(printf '%s' "$JSON" | python3 -c '
import json,sys
try:
    d = json.load(sys.stdin).get("data", {})
    f = ",".join(d.get("failing", [])) or "unspecified"
    print("%s (backup_age=%sh rss=%sMB/%s)" % (f, d.get("backup_age_hours"), d.get("rss_mb"), d.get("rss_limit_mb")))
except Exception:
    print("http %s, unparseable body" % "'"$CODE"'")' 2>/dev/null || echo "http $CODE")
fi

# A sibling unit stuck in a restart loop produces NO signal anywhere: /health is
# in-process and knows nothing about systemd, /ready knows nothing about the
# other units, and the external monitor only polls the healthy one. M49 found
# grange-follower.service failing every two seconds for as long as it had
# existed, next to a grange-read.service that was fine. This asks systemd
# directly, for grange units only, and folds the answer into the same alert.
LOOPING=""
# SYSTEMCTL is overridable so this branch can be exercised by a test with a stub:
# a restart-loop check that has never been seen to fire is a check nobody has
# tested, and this project has shipped five of those.
SYSTEMCTL="${SYSTEMCTL:-systemctl}"
if command -v "$SYSTEMCTL" >/dev/null 2>&1; then
  LOOPING=$($SYSTEMCTL list-units --type=service --all --no-legend --plain 'grange*' 2>/dev/null \
            | awk '$3 == "failed" || $3 == "activating" { print $1 }' | tr '\n' ' ' | sed 's/ $//')
  # `activating` is normal for a second or two after a restart, so confirm it is
  # actually looping rather than merely starting — otherwise this alerts on every
  # deploy, which is the fastest way to get itself muted.
  if [ -n "$LOOPING" ]; then
    CONFIRM=""
    for u in $LOOPING; do
      NR=$($SYSTEMCTL show -p NRestarts --value "$u" 2>/dev/null || echo 0)
      ST=$($SYSTEMCTL show -p ActiveState --value "$u" 2>/dev/null || echo "")
      if [ "$ST" = "failed" ] || { [ "${NR:-0}" -gt 3 ] 2>/dev/null && [ "$ST" != "active" ]; }; then
        CONFIRM="$CONFIRM $u(restarts=$NR,$ST)"
      fi
    done
    LOOPING=$(printf '%s' "$CONFIRM" | sed 's/^ //')
  fi
fi
if [ -n "$LOOPING" ]; then
  # a sick sibling does not make THIS server unready, but it must be reported
  [ "$NOW" = "ok" ] && NOW="sibling-failing"
  DETAIL="$DETAIL; units failing:$LOOPING"
fi

WAS=$(cat "$STATE" 2>/dev/null || echo "unknown")
echo "$NOW" > "$STATE" 2>/dev/null || true

SENT=false
notify() {
  [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 0
  SENT=true
  curl -s -m 15 -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TG_CHAT" --data-urlencode "text=$1" >/dev/null 2>&1
}

if [ "$NOW" != "$WAS" ]; then
  if [ "$NOW" = "ok" ]; then
    [ "$WAS" = "unknown" ] || notify "grange readiness RECOVERED on $(hostname): $URL"
  else
    notify "grange NOT READY on $(hostname) [$NOW]: $DETAIL"
  fi
fi

# `transition` is whether the state CHANGED; `notified` is whether a message was
# actually sent. Reporting one as the other made the first run claim it had
# alerted when it deliberately had not.
echo "{\"state\":\"$NOW\",\"previous\":\"$WAS\",\"http\":\"$CODE\",\"units_failing\":\"$LOOPING\",\"detail\":\"$DETAIL\",\"transition\":$([ "$NOW" != "$WAS" ] && echo true || echo false),\"notified\":$SENT}"
[ "$NOW" = "ok" ] || exit 1
