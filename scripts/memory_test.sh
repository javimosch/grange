#!/bin/bash
# memory_test.sh — verify the /memory endpoint and the arena-reset fix.
# /memory exposes RSS, limit, arena resets, loaded collections, and config.
# The arena reset re-opens the default collection so cold state is reloaded
# from disk (fixes ARENA003 corruption on g_run_pages/g_run_rid).
set -e
cd "$(dirname "$0")/.."
BIN=./grange
DB=$(mktemp -d)
PORT=4999
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

$BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/mem_pri.log 2>&1 &
SRV=$!
sleep 1
B=http://127.0.0.1:$PORT

# 1. /memory requires admin
RES=$(curl -s "$B/memory")
contains "$RES" '"auth"' && check "auth" "auth" "memory requires admin" || check "$RES" "auth" "memory requires admin"

# 2. /memory returns the full picture
RES=$(curl -s "$B/memory" -H "Authorization: Bearer $TOKEN")
contains "$RES" 'rss_kb' && contains "$RES" 'rss_limit_mb' && contains "$RES" 'arena_resets' && check "fields" "fields" "memory endpoint has all fields" || check "$RES" "fields" "memory endpoint has all fields"

# 3. Write docs, check count
for i in 1 2 3; do curl -s -X POST $B/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":1}}' >/dev/null; done
RRES=$(curl -s "$B/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":3' && check "count" "count" "writes before reset" || check "$RRES" "count" "writes before reset"

# 4. Arena reset with GRANGE_RESET_EVERY=2
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
GRANGE_RESET_EVERY=2 $BIN serve --db "$DB" --port $PORT --token $TOKEN > /tmp/mem_reset.log 2>&1 &
SRV=$!
sleep 1
for i in 1 2 3 4 5; do
  curl -s -X POST $B/put -H "Authorization: Bearer $TOKEN" -d '{"doc":{"v":1}}' >/dev/null
  curl -s "$B/count" -H "Authorization: Bearer $TOKEN" >/dev/null
done
RRES=$(curl -s "$B/count" -H "Authorization: Bearer $TOKEN")
contains "$RRES" '"count":8' && check "post-reset" "post-reset" "count survives arena resets" || check "$RRES" "post-reset" "count survives arena resets"

# 5. /memory shows resets
RES=$(curl -s "$B/memory" -H "Authorization: Bearer $TOKEN")
echo "$RES" | grep -q '"arena_resets":[1-9]' && check "reset-count" "reset-count" "memory shows reset count" || check "$RES" "reset-count" "memory shows reset count"

kill $SRV 2>/dev/null; wait $SRV 2>/dev/null
rm -rf "$DB"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && echo '{"ok":true,"memory":"pass"}' || { echo '{"ok":false,"memory":"fail"}'; exit 1; }
