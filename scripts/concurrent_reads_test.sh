#!/bin/bash
# concurrent_reads_test.sh — verify GRANGE_CONCURRENT_READS=1 auto-spawns a
# follower and proxies reads to it, giving real read concurrency.
# Retrocompatible: off by default, and manual --read-proxy takes precedence.
set -e
cd "$(dirname "$0")/.."
BIN=./grange
DB=$(mktemp -d)
PORT=4899
FPORT=$((PORT + 1))
TOKEN=admintok
PASS=0
FAIL=0

check() {
    if [ "$1" = "$2" ]; then
        echo "  ok: $3"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $3 (got '$1' expected '$2')"
        FAIL=$((FAIL + 1))
    fi
}

contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *) return 1 ;;
    esac
}

# 1. GRANGE_CONCURRENT_READS=1 auto-spawns a follower
GRANGE_CONCURRENT_READS=1 $BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/cr_pri.log 2>&1 &
PRI=$!
sleep 2
B=http://127.0.0.1:$PORT

contains "$(cat /tmp/cr_pri.log)" 'follower_spawned' && check "spawned" "spawned" "auto-follower spawned" || check "$(cat /tmp/cr_pri.log)" "spawned" "auto-follower spawned"

# 2. Follower is listening on FPORT
ss -tlnp | grep -q ":$FPORT" && check "listening" "listening" "follower listening on port+1" || check "no-listen" "listening" "follower listening on port+1"

# 3. Write to primary
WRES=$(curl -s -X POST $B/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":1}}')
contains "$WRES" '"ok":true' && check "write" "write" "primary accepts writes" || check "write-fail" "write" "primary accepts writes"

# 4. Read from primary (proxied to follower)
RRES=$(curl -s "$B/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":1' && check "proxy-read" "proxy-read" "read proxied to follower" || check "$RRES" "proxy-read" "read proxied to follower"

# 5. Read from follower directly
RRES=$(curl -s "http://127.0.0.1:$FPORT/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":1' && check "fol-read" "fol-read" "follower has the data" || check "$RRES" "fol-read" "follower has the data"

# 6. Without GRANGE_CONCURRENT_READS, no follower spawned
kill $PRI 2>/dev/null; wait $PRI 2>/dev/null
# kill the auto-spawned follower by its port
FOLPID=$(ss -tlnp 2>/dev/null | grep ":$FPORT" | grep -oP 'pid=\K[0-9]+' | head -1)
if [ -n "$FOLPID" ]; then kill $FOLPID 2>/dev/null; fi
sleep 1

$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/cr_pri2.log 2>&1 &
PRI=$!
sleep 1
if contains "$(cat /tmp/cr_pri2.log)" 'follower_spawned'; then
    check "spawned-bad" "no-spawn" "no auto-follower without flag"
else
    check "no-spawn" "no-spawn" "no auto-follower without flag"
fi

kill $PRI 2>/dev/null; wait $PRI 2>/dev/null
FOLPID=$(ss -tlnp 2>/dev/null | grep ":$FPORT" | grep -oP 'pid=\K[0-9]+' | head -1)
if [ -n "$FOLPID" ]; then kill $FOLPID 2>/dev/null; fi
rm -rf "$DB"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && echo '{"ok":true,"concurrent_reads":"pass"}' || { echo '{"ok":false,"concurrent_reads":"fail"}'; exit 1; }
