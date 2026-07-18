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
