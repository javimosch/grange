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
probe GET  /ready
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

# A MISTYPED route must 404, not answer. Most routes were matched with
# has_prefix(req.path, "/count") — req.path carries the query string, so that was
# the obvious way to write it — and it also matched /counter and /countXYZ, which
# returned a perfectly plausible count. For an agent-first API that is worse than
# an error: it teaches a wrong URL by rewarding it. Found by a negative control in
# the journey harness that refused to fail.
ghosts=0
for gp in counter countXYZ findx getx aggx statsx readyx verifyx usagex exportx collectionsx; do
  body=$(curl -s -m 10 "http://localhost:$PORT/$gp?coll=c" -H "authorization: Bearer $TOK" 2>/dev/null)
  echo "$body" | grep -q "no such route" || { echo "GHOST /$gp answered instead of 404: $(echo "$body" | head -c 55)"; ghosts=$((ghosts + 1)); }
done
if [ "$ghosts" = "0" ]; then echo "ok mistyped routes 404 instead of answering (11 probed)"
else echo "FAIL $ghosts mistyped route(s) answered"; fails=$((fails + ghosts)); fi
# ...and the real routes still work, with and without a query string
for rp in "/count" "/count?coll=c" "/ready" "/verify?coll=c"; do
  body=$(curl -s -m 10 "http://localhost:$PORT$rp" -H "authorization: Bearer $TOK" 2>/dev/null)
  echo "$body" | grep -q "no such route" && { echo "FAIL real route $rp stopped working"; fails=$((fails + 1)); }
done

# HEAD must agree with GET, and carry no body (RFC 9110).
#
# A HEAD used to match no GET route, fall through to the auth gate, and answer
# 401 — including on /llms.txt, the one route the contract promises is open to
# anyone. `curl -I` said 401 while `curl` said 200, so every link checker and
# uptime probe was told the front door was locked. No test here had ever issued
# a HEAD, which is exactly why it survived for the life of the project.
for R in "/llms.txt" "/health" "/count?coll=c" "/ready" "/guide"; do
  G=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -H "authorization: Bearer $TOK" "http://localhost:$PORT$R")
  H=$(curl -s -m 10 -I -o /dev/null -w '%{http_code}' -H "authorization: Bearer $TOK" "http://localhost:$PORT$R")
  if [ "$G" = "$H" ]; then echo "ok HEAD agrees with GET on $R ($G)"
  else echo "FAIL HEAD $R returns $H but GET returns $G"; fails=$((fails + 1)); fi
done
if python3 -c "
import socket, sys
s = socket.create_connection(('127.0.0.1', $PORT), 5)
s.sendall(b'HEAD /llms.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
d = b''
while True:
    c = s.recv(65536)
    if not c: break
    d += c
head, _, body = d.partition(b'\r\n\r\n')
sys.exit(0 if len(body) == 0 else 1)"; then
  echo "ok HEAD returns headers only, no body"
else
  echo "FAIL HEAD returned a body"; fails=$((fails + 1))
fi

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

