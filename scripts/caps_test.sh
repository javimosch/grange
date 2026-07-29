#!/usr/bin/env bash
# M15 e2e: fair-use caps + traceability (429s, journal line, /usage counter,
# persistence across restart, per-tenant watcher cap).
set -e
BIN="${1:-./grange}"
fuser -k 4495/tcp 2>/dev/null || true
sleep 0.3
D=$(mktemp -d /tmp/grange-caps-XXXX)
trap 'fuser -k 4495/tcp 2>/dev/null || true' EXIT
GRANGE_RATE_PER_MIN=20 "$BIN" serve --db "$D" --port 4495 --token tk > "$D/log" 2>&1 &
P=$!
sleep 0.5
TT=$(curl -s -X POST localhost:4495/tenants -H "X-Peage-Wallet: pw_x" -d '{}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")

# A tenant must be able to STORE AND READ ITS OWN DATA, in a named database.
# Nothing tested this: the harnesses drive a single-tenant server with --db, and
# the tenant path resolves a different root entirely. A refactor moved that
# resolution into a callee that took `root` BY VALUE, so every tenant data
# request silently opened the admin root and returned "docs": 0 on a collection
# holding 1123 documents — in production, past a full green gate.
TA="Authorization: Bearer $TT"
curl -s -X POST "localhost:4495/put" -H "$TA" -d '{"db":"appdb","coll":"leads","id":"l1","doc":{"co":"acme","score":9}}' >/dev/null
curl -s -X POST "localhost:4495/put" -H "$TA" -d '{"db":"appdb","coll":"leads","id":"l2","doc":{"co":"beta","score":4}}' >/dev/null
TC=$(curl -s "localhost:4495/count?db=appdb&coll=leads" -H "$TA" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
if [ "$TC" = "2" ]; then echo "tenant data: stored and read back in its own db"; else echo "FAIL tenant data: count=$TC, expected 2"; exit 1; fi
TG=$(curl -s "localhost:4495/get?db=appdb&coll=leads&id=l1" -H "$TA" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(d["doc"]["co"])' 2>/dev/null || echo MISSING)
if [ "$TG" = "acme" ]; then echo "tenant data: get by id returns the document"; else echo "FAIL tenant get: $TG"; exit 1; fi
# a SECOND database for the same tenant must be isolated from the first
curl -s -X POST "localhost:4495/put" -H "$TA" -d '{"db":"other","coll":"leads","id":"x","doc":{"co":"zzz"}}' >/dev/null
OC=$(curl -s "localhost:4495/count?db=other&coll=leads" -H "$TA" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
if [ "$OC" = "1" ]; then echo "tenant data: a second db is separate"; else echo "FAIL tenant db isolation: count=$OC, expected 1"; exit 1; fi
# ...and it must land in the TENANT'S directory on disk. Checking only that a
# write can be read back is NOT enough: with the root misresolved, writes and
# reads use the same wrong directory and agree with each other perfectly. What
# broke in production was EXISTING data becoming invisible, so the assertion has
# to be about WHERE the bytes are, not about round-tripping.
if [ -d "$D.tenants" ] && ls -d "$D.tenants"/*/appdb/leads >/dev/null 2>&1; then
  echo "tenant data: stored under the tenant's own root on disk"
else
  echo "FAIL tenant data landed outside the tenant root: $(ls -d "$D.tenants"/*/ 2>/dev/null | head -2) $(ls "$D" 2>/dev/null | head -5)"
  exit 1
fi
if ls -d "$D/appdb" >/dev/null 2>&1; then
  echo "FAIL tenant data leaked into the ADMIN root ($D/appdb exists)"
  exit 1
fi

# and the ADMIN token must not see the tenant's collection under its own root
AC=$(curl -s "localhost:4495/count?db=appdb&coll=leads" -H "Authorization: Bearer tk" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo err)
if [ "$AC" = "0" ] || [ "$AC" = "err" ]; then echo "tenant data: admin root does not see tenant data"; else echo "FAIL isolation: admin saw $AC docs"; exit 1; fi

A="Authorization: Bearer $TT"
ok=0; limited=0
for i in $(seq 1 30); do
  C=$(curl -s -o /dev/null -w "%{http_code}" "localhost:4495/count" -H "$A")
  [ "$C" = "200" ] && ok=$((ok+1)); [ "$C" = "429" ] && limited=$((limited+1))
done
echo "requests: $ok ok, $limited limited (limit 20/min)"
[ "$limited" -ge 9 ] || { echo FAIL; exit 1; }
curl -s "localhost:4495/count" -H "$A" | grep -q "retry_after_seconds" && echo "429 body carries retry_after_seconds"
grep -q '"event":"rate_limited"' "$D/log" && echo "journal trace line emitted: $(grep rate_limited "$D/log" | head -1)"
# watcher cap on a SECOND tenant (own rate window): park 5 for real, 6th rejected
T2=$(curl -s -X POST localhost:4495/tenants -H "X-Peage-Wallet: pw_y" -d '{}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")
A2="Authorization: Bearer $T2"
SEQ=$(curl -s "localhost:4495/watch?since=0&timeout=1" -H "$A2" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['seq'])")
for i in 1 2 3 4 5; do (curl -s "localhost:4495/watch?since=$SEQ&timeout=8" -H "$A2" >/dev/null 2>&1 &) ; done
sleep 0.8
W=$(curl -s "localhost:4495/watch?since=$SEQ&timeout=8" -H "$A2")
if echo "$W" | grep -q "watch-capacity"; then echo "6th watcher rejected (per-tenant cap 5)"; else echo "FAIL watcher cap: $W"; exit 1; fi
# shutdown flushes throttle counters; restart shows them in /usage
curl -s -X POST localhost:4495/shutdown -H "Authorization: Bearer tk" >/dev/null || true; sleep 0.5
GRANGE_RATE_PER_MIN=5 "$BIN" serve --db "$D" --port 4495 --token tk >> "$D/log" 2>&1 &
P=$!
sleep 0.5
U=$(curl -s "localhost:4495/usage" -H "$A")
echo "usage after restart: $U"
echo "$U" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; assert d['throttled_requests_total'] >= 6, d; print('throttle counter persisted:', d['throttled_requests_total'])"
curl -s -X POST localhost:4495/shutdown -H "Authorization: Bearer tk" >/dev/null || true
rm -rf "$D"
echo '{"ok":true,"caps_suite":"pass"}'
