#!/usr/bin/env bash
# M12 e2e: (1) local read-only follower on the same dir catches up via WAL,
# (2) remote replication over the watch feed (follow verb), incl. deletes.
set -e
BIN="${1:-./grange}"
D=$(mktemp -d /tmp/grange-repl-XXXX)
"$BIN" serve --db "$D/primary" --port 4491 --token ptk >/dev/null 2>&1 &
P1=$!
sleep 0.5
TT=$(curl -s -X POST localhost:4491/tenants -H "X-Peage-Wallet: pw_x" -d '{}' | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")
A="Authorization: Bearer $TT"
curl -s -X POST localhost:4491/put -H "$A" -d '{"coll":"c","id":"a","doc":{"v":1}}' >/dev/null

# --- local follower: same tenant dir, read-only, refreshes from disk ---
"$BIN" serve --db "$D/primary" --port 4492 --token ptk --follow >/dev/null 2>&1 &
P2=$!
sleep 0.5
R1=$(curl -s "localhost:4492/get?coll=c&id=a" -H "$A")
echo "$R1" | grep -q '"v":1' && echo "follower sees initial doc"
curl -s -X POST localhost:4491/put -H "$A" -d '{"coll":"c","id":"b","doc":{"v":2}}' >/dev/null
R2=$(curl -s "localhost:4492/count?coll=c" -H "$A")
echo "$R2" | grep -q '"count":2' && echo "follower caught up via WAL refresh"
W=$(curl -s -X POST localhost:4492/put -H "$A" -d '{"coll":"c","doc":{"nope":1}}')
echo "$W" | grep -q "read-only" && echo "follower rejects writes"

# --- remote replication: follow into a fresh local db ---
"$BIN" follow --from http://localhost:4491 --rtoken "$TT" --remote-coll c --db "$D/replica" --coll c --once >/dev/null 2>&1
C=$("$BIN" count --db "$D/replica" --coll c | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['count'])")
[ "$C" = "2" ] && echo "remote replica resynced 2 docs"
curl -s -X POST localhost:4491/put -H "$A" -d '{"coll":"c","id":"cdoc","doc":{"v":3}}' >/dev/null
curl -s -X POST localhost:4491/del -H "$A" -d '{"coll":"c","id":"a"}' >/dev/null
"$BIN" follow --from http://localhost:4491 --rtoken "$TT" --remote-coll c --db "$D/replica" --coll c --once >/dev/null 2>&1
C2=$("$BIN" count --db "$D/replica" --coll c | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['count'])")
G=$("$BIN" get --db "$D/replica" --coll c --id cdoc | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['doc']['v'])")
[ "$C2" = "2" ] && [ "$G" = "3" ] && echo "delta replication applied put+del correctly"
kill -9 $P1 $P2 2>/dev/null
rm -rf "$D"
echo '{"ok":true,"replica_suite":"pass"}'
