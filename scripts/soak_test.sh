#!/usr/bin/env bash
# Soak: every route, many times, against ONE long-lived server.
#
# Written after a shipped bug that the entire rest of the gate could not see.
# An ordered query built the sorted projection INSIDE the request's scoped
# arena; the projection is stored in a global, so when the arena was freed at
# the end of the request the global pointed at freed memory and the SECOND
# ordered query killed the server. Deterministic, remotely triggerable, and
# invisible to:
#
#   · the unit suites   — they call the query functions in-process, with no
#                         request arena around them
#   · the differential fuzz — same, in-process
#   · routes_test.sh    — one request per route, then the server is torn down
#   · isolation/durability/caps — each starts a fresh server for its own check
#
# Nothing anywhere hit one route TWICE on one process. That is exactly the shape
# of every arena/global lifetime bug, which is the failure class a single
# long-lived actor is most exposed to.
#
# So: keep one server up, call everything repeatedly, and assert both that it is
# still alive and that answers do not change between identical calls.
set -u
BIN="${1:-./grange}"
PORT="${2:-4499}"
ROUNDS="${3:-4}"
DB=$(mktemp -d /tmp/grange-soak-XXXX); rm -rf "$DB"
TOK=soaktk
A="authorization: Bearer $TOK"
fails=0

fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

u() { echo "http://localhost:$PORT$1"; }
get() { curl -s -m 10 "$(u "$1")" -H "$A"; }
post() { curl -s -m 10 -X POST "$(u "$1")" -H "$A" -d "${2:-}"; }

alive() { curl -s -m 5 "$(u /health)" -H "$A" | grep -q '"up"'; }

check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# seed both a hot and a cold collection, each with equality and range indexes
python3 -c "
import json
print('\n'.join('k%d\t%s' % (i, json.dumps({'ts': 1785000000+i, 'site': 'a.io' if i%3 else 'b.io', 'v': i%50})) for i in range(4000)))
" > /tmp/gsoak.txt
post "/bulk?coll=hot" "@" >/dev/null 2>&1
curl -s -m 60 -X POST "$(u '/bulk?coll=hot')" -H "$A" --data-binary @/tmp/gsoak.txt >/dev/null
post "/cold?coll=cold" '{}' >/dev/null
curl -s -m 60 -X POST "$(u '/bulk?coll=cold')" -H "$A" --data-binary @/tmp/gsoak.txt >/dev/null
for c in hot cold; do
  post /index "{\"coll\":\"$c\",\"field\":\"site\"}" >/dev/null
  post /index "{\"coll\":\"$c\",\"field\":\"ts\",\"kind\":\"range\"}" >/dev/null
done

# every read route, on both storage modes, repeated. The FIRST response of each
# is the reference: an identical later call must give an identical answer.
declare -a PATHS=()
for c in hot cold; do
  PATHS+=("/count?coll=$c")
  PATHS+=("/count?coll=$c&where=site%3Da.io")
  PATHS+=("/count?coll=$c&where=ts%3E%3D1785002000,ts%3C1785003000")
  PATHS+=("/find?coll=$c&limit=5")
  PATHS+=("/find?coll=$c&where=site%3Da.io&limit=5")
  PATHS+=("/find?coll=$c&limit=5&order=-ts")
  PATHS+=("/find?coll=$c&limit=5&order=ts")
  PATHS+=("/find?coll=$c&where=ts%3E%3D1785002000,ts%3C1785003000&limit=5&order=-ts")
  PATHS+=("/find?coll=$c&where=site%3Da.io&limit=3&order=-ts")
  PATHS+=("/agg?coll=$c&group-by=site")
  PATHS+=("/get?coll=$c&id=k7")
  PATHS+=("/stats?coll=$c")
  PATHS+=("/verify?coll=$c")
  PATHS+=("/export?coll=$c")
done
PATHS+=("/collections" "/health" "/usage" "/guide")

start_server() {
  fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
  "$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
  SRV=$!
  for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
}

declare -A FIRST=()
for r in $(seq 1 "$ROUNDS"); do
  # RESTART before round 2. This is not decoration: lazily-built state (the
  # sorted projection) is warm in the process that declared the index, so a
  # single-process soak silently tests the easy path. After a restart the first
  # query is the one that BUILDS it — which is exactly when building it in the
  # request's arena leaves a dangling global. The RSS watchdog restarts this
  # server in production, so "state built by a previous process" is the normal
  # case, not an exotic one.
  if [ "$r" = "2" ]; then
    post /shutdown '' >/dev/null 2>&1; sleep 0.5
    kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
    start_server
    echo "  (server restarted before round 2)"
    # The FIRST query after the restart must be one that forces lazily-built
    # state to be built, and it must be issued through the path under test —
    # here an ordered query, which is the only caller that builds the sorted
    # projection without going through q_warm. Relying on PATHS order for this
    # is fragile: a range `where` query earlier in the list warms the projection
    # outside any arena and hides the bug entirely (it did).
    for c in hot cold; do
      first=$(get "/find?coll=$c&limit=5&order=-ts")
      [ -n "$first" ] && check "cold-start ordered query answers ($c)" 1 \
                      || check "cold-start ordered query answers ($c)" 0
      second=$(get "/find?coll=$c&limit=5&order=-ts")
      if [ -n "$second" ] && [ "$first" = "$second" ]; then
        check "and the one after it, identically ($c)" 1
      else
        check "and the one after it, identically ($c) — server died or answer changed" 0
        alive || { echo "  server is DEAD after a cold-start ordered query ($c)"
                   rm -rf "$DB"; echo '{"ok":false,"dead":true}'; exit 1; }
      fi
    done
  fi
  for p in "${PATHS[@]}"; do
    body=$(get "$p")
    if [ -z "$body" ]; then
      check "server answered $p (round $r)" 0
      # a dead server makes every later check meaningless
      if ! alive; then
        echo "  server is DEAD after: $p (round $r)"
        rm -rf "$DB"; echo '{"ok":false,"failures":'"$((fails))"',"dead":true}'; exit 1
      fi
      continue
    fi
    # some answers legitimately move: /stats reports rss, /usage reports
    # counters, and /verify counts FILES (each write adds a WAL chunk). For
    # verify the invariant worth asserting is that it still reports intact.
    case "$p" in
      */verify*)
        echo "$body" | grep -q '"intact":true' || check "verify still reports intact: $p (round $r)" 0
        ;;
      */stats*|*/usage*) ;;
      *)
        if [ -z "${FIRST[$p]+x}" ]; then
          FIRST[$p]=$body
        elif [ "${FIRST[$p]}" != "$body" ]; then
          check "identical call gives identical answer: $p (round $r)" 0
        fi
        ;;
    esac
  done
  # writes between read rounds: the arena churn a real server actually sees
  post /put "{\"coll\":\"hot\",\"id\":\"soak$r\",\"doc\":{\"ts\":178500$r,\"site\":\"c.io\",\"v\":$r}}" >/dev/null
  post /del "{\"coll\":\"hot\",\"id\":\"soak$r\"}" >/dev/null
done

alive && check "server alive after $ROUNDS rounds over ${#PATHS[@]} routes" 1 \
       || check "server alive after $ROUNDS rounds" 0

post /shutdown '' >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"soak_rounds":'"$ROUNDS"',"routes":'"${#PATHS[@]}"'}'
  exit 0
fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
