#!/bin/bash
# rbac_test.sh — verify read-only token role enforcement.
# A read-only ("ro") token can read (GET) but not write (POST /put /del /bulk
# /index /cold /compact /shutdown). Existing tokens default to "rw".
# Retrocompatibility: a token issued before RBAC existed has no role record
# and defaults to "rw", so existing deployments are unaffected.
set -e
cd "$(dirname "$0")/.."
BIN=./grange
DB=$(mktemp -d)
PORT=4699
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

$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/rbac_out.log 2>&1 &
BGPID=$!
sleep 1
B=http://127.0.0.1:$PORT

# 1. Create a tenant
TENANT=$(curl -s -X POST $B/tenants -H "X-Peage-Wallet: pw_test" -d '{"name":"rbac"}')
TTOK=$(echo "$TENANT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["token"])')

# 2. Write with the rw token (should work)
WRES=$(curl -s -X POST $B/put -H "Authorization: Bearer $TTOK" -d '{"doc":{"v":1}}')
contains "$WRES" '"ok":true' && check "write-ok" "write-ok" "rw token can write" || check "write-fail" "write-ok" "rw token can write"

# 3. Issue a read-only token
RO=$(curl -s -X POST $B/tokens -H "Authorization: Bearer $TTOK" -d '{"role":"ro"}')
ROTK=$(echo "$RO" | python3 -c 'import json,sys;print(json.load(sys.stdin)["data"]["token"])')

# 4. Read with ro token (should work)
RRES=$(curl -s "$B/count" -H "Authorization: Bearer $ROTK")
contains "$RRES" '"count":1' && check "read-ok" "read-ok" "ro token can read" || check "read-fail" "read-ok" "ro token can read"

# 5. Write with ro token (should 403 read-only)
WRES=$(curl -s -X POST $B/put -H "Authorization: Bearer $ROTK" -d '{"doc":{"v":2}}')
contains "$WRES" 'read-only' && check "ro-blocked" "ro-blocked" "ro token blocked from /put" || check "$WRES" "ro-blocked" "ro token blocked from /put"

# 6. Delete with ro token (should 403)
DRES=$(curl -s -X POST $B/del -H "Authorization: Bearer $ROTK" -d '{"id":"x"}')
contains "$DRES" 'read-only' && check "del-blocked" "del-blocked" "ro token blocked from /del" || check "$DRES" "del-blocked" "ro token blocked from /del"

# 7. Compact with ro token (should 403)
CRES=$(curl -s -X POST $B/compact -H "Authorization: Bearer $ROTK")
contains "$CRES" 'read-only' && check "compact-blocked" "compact-blocked" "ro token blocked from /compact" || check "$CRES" "compact-blocked" "ro token blocked from /compact"

# 8. rw token still works (retrocompat)
WRES=$(curl -s -X POST $B/put -H "Authorization: Bearer $TTOK" -d '{"doc":{"v":3}}')
contains "$WRES" '"ok":true' && check "rw-still" "rw-still" "rw token still writes" || check "rw-fail" "rw-still" "rw token still writes"

# 9. Bad role rejected
BRES=$(curl -s -X POST $B/tokens -H "Authorization: Bearer $TTOK" -d '{"role":"admin"}')
contains "$BRES" 'must be' && check "bad-role" "bad-role" "bad role rejected" || check "$BRES" "bad-role" "bad role rejected"

# 10. ro token persists across restart
kill $BGPID 2>/dev/null; wait $BGPID 2>/dev/null
$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/rbac_out2.log 2>&1 &
BGPID=$!
sleep 1
RRES=$(curl -s "$B/count" -H "Authorization: Bearer $ROTK")
contains "$RRES" '"count"' && check "ro-persist" "ro-persist" "ro token survives restart" || check "$RRES" "ro-persist" "ro token survives restart"
WRES=$(curl -s -X POST $B/put -H "Authorization: Bearer $ROTK" -d '{"doc":{"v":4}}')
contains "$WRES" 'read-only' && check "ro-blocked-after" "ro-blocked-after" "ro blocked after restart" || check "$WRES" "ro-blocked-after" "ro blocked after restart"

kill $BGPID 2>/dev/null; wait $BGPID 2>/dev/null
rm -rf "$DB"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && echo '{"ok":true,"rbac":"pass"}' || { echo '{"ok":false,"rbac":"fail"}'; exit 1; }
