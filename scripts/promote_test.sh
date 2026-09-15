#!/bin/bash
# promote_test.sh — verify automated failover via POST /promote.
# A follower (--follow) is read-only. POST /promote flips it to primary so
# it accepts writes. This is the automated-failover primitive: when the
# primary is down, an operator POSTs /promote to the follower.
set -e
cd "$(dirname "$0")/.."
BIN=./grange
DB=$(mktemp -d)
PORT1=4799
PORT2=4800
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

$BIN serve --db "$DB" --port $PORT1 --token $TOKEN > /tmp/promote_pri.log 2>&1 &
PRI=$!
$BIN serve --db "$DB" --port $PORT2 --token $TOKEN --follow > /tmp/promote_fol.log 2>&1 &
FOL=$!
sleep 1
B1=http://127.0.0.1:$PORT1
B2=http://127.0.0.1:$PORT2

# 1. Write to primary
WRES=$(curl -s -X POST $B1/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":1}}')
contains "$WRES" '"ok":true' && check "pri-write" "pri-write" "primary accepts writes" || check "pri-fail" "pri-write" "primary accepts writes"

# 2. Read from follower
RRES=$(curl -s "$B2/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":1' && check "fol-read" "fol-read" "follower reads primary data" || check "$RRES" "fol-read" "follower reads primary data"

# 3. Write to follower (should 403)
WRES=$(curl -s -X POST $B2/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":2}}')
contains "$WRES" 'read-only' && check "fol-blocked" "fol-blocked" "follower rejects writes" || check "$WRES" "fol-blocked" "follower rejects writes"

# 4. Promote follower
PRES=$(curl -s -X POST $B2/promote -H "Authorization: Bearer $TOKEN")
contains "$PRES" '"promoted":true' && check "promote" "promote" "follower promoted" || check "$PRES" "promote" "follower promoted"

# 5. Write to follower after promote (should work)
WRES=$(curl -s -X POST $B2/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":3}}')
contains "$WRES" '"ok":true' && check "fol-write" "fol-write" "promoted follower accepts writes" || check "$WRES" "fol-write" "promoted follower accepts writes"

# 6. Read from promoted follower
RRES=$(curl -s "$B2/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":2' && check "fol-count" "fol-count" "promoted follower has both docs" || check "$RRES" "fol-count" "promoted follower has both docs"

# 7. Promote non-admin (should 403)
PRES=$(curl -s -X POST $B2/promote)
contains "$PRES" '"auth"' && check "promote-auth" "promote-auth" "promote requires admin" || check "$PRES" "promote-auth" "promote requires admin"

# 8. Promote primary (no-op, was_follower=0)
PRES=$(curl -s -X POST $B1/promote -H "Authorization: Bearer $TOKEN")
contains "$PRES" '"was_follower":0' && check "promote-pri" "promote-pri" "promote on primary is no-op" || check "$PRES" "promote-pri" "promote on primary is no-op"

kill $PRI $FOL 2>/dev/null; wait $PRI $FOL 2>/dev/null
rm -rf "$DB"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && echo '{"ok":true,"promote":"pass"}' || { echo '{"ok":false,"promote":"fail"}'; exit 1; }
