#!/usr/bin/env bash
# Route inventory. Written after an edit to serve.src silently deleted the
# /watch route: all six unit suites passed, because nothing unit-tests the HTTP
# surface — only the replication fuzz noticed, and only via its remote step.
#
# This asserts the server ANSWERS every route it publishes. It deliberately does
# not check semantics (the suites and fuzzes do that); a route that 404s is the
# failure mode this catches, and the cheapest one to regress.
set -u
BIN="${1:-./grange}"
PORT="${2:-4497}"
DB=$(mktemp -d /tmp/grange-routes-XXXX)
TOK=routestk
fails=0

"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 60); do
  sleep 0.1
  curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break
done

probe() { # method path [body]
  local m=$1 p=$2 b=${3:-}
  local out
  if [ -n "$b" ]; then
    out=$(curl -s -X "$m" "http://localhost:$PORT$p" -H "authorization: Bearer $TOK" --data-binary "$b" 2>&1)
  else
    out=$(curl -s -X "$m" "http://localhost:$PORT$p" -H "authorization: Bearer $TOK" 2>&1)
  fi
  if echo "$out" | grep -q "no such route"; then
    echo "MISSING $m $p"
    fails=$((fails + 1))
  fi
}

probe GET  /health
probe GET  /collections
probe GET  /stats
probe GET  /usage
probe GET  /verify
probe GET  /export
probe GET  "/get?coll=c&id=x"
probe GET  "/find?coll=c"
probe GET  "/count?coll=c"
probe GET  "/agg?coll=c&op=count&field=v"
probe GET  "/watch?coll=c&since=0&timeout=1"
probe POST /put   '{"coll":"c","id":"a","doc":{"v":1}}'
probe POST /del   '{"coll":"c","id":"a"}'
probe POST "/bulk?coll=c" 'b	{"v":2}'
probe POST /index '{"coll":"c","field":"v"}'
probe POST /cold  '{"coll":"c2"}'
probe POST /compact '{"coll":"c"}'
probe POST /tenants '{"name":"t"}'

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"routes_missing":0}'
  exit 0
fi
echo '{"ok":false,"routes_missing":'"$fails"'}'
exit 1
