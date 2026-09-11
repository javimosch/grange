#!/usr/bin/env bash
# Disk full / write error handling test.
#
# Simulates disk full by making the database directory read-only after creating
# it, then verifies that put/del return exit code 90 (disk-full) instead of
# crashing.  Also tests the HTTP serve mode returns 507 Insufficient Storage.
set -u
BIN="${1:-./grange}"
fails=0

echo "  disk full / write error handling:"

# --- Part 1: CLI put with read-only directory ---
DB=$(mktemp -d /tmp/grange-disk-full-XXXX)

# seed the database first (needs write access)
"$BIN" put --db "$DB" --coll c --id seed --doc '{"v":0}' >/dev/null 2>&1

# make the collection directory read-only to simulate disk full / write error
chmod 555 "$DB/c"

# attempt a put — should get exit 90, not a crash
OUT=$("$BIN" put --db "$DB" --coll c --id x --doc '{"v":1}' 2>&1)
RC=$?
if [ "$RC" -eq 90 ]; then
  echo "  ok   put returns exit 90 (disk-full) on write error"
elif [ "$RC" -ge 110 ]; then
  echo "  FAIL put crashed with exit $RC on write error: $OUT"
  fails=$((fails + 1))
elif [ "$RC" -eq 0 ]; then
  echo "  FAIL put succeeded despite read-only directory (exit 0)"
  fails=$((fails + 1))
else
  echo "  FAIL put returned unexpected exit $RC: $OUT"
  fails=$((fails + 1))
fi

# verify the error message mentions disk-full
if echo "$OUT" | grep -q "disk.full\|disk full"; then
  echo "  ok   error message mentions disk full"
else
  echo "  WARN error message does not mention disk full: $OUT"
fi

# attempt a del — should also get exit 90
OUT=$("$BIN" del --db "$DB" --coll c --id seed 2>&1)
RC=$?
if [ "$RC" -eq 90 ]; then
  echo "  ok   del returns exit 90 (disk-full) on write error"
elif [ "$RC" -ge 110 ]; then
  echo "  FAIL del crashed with exit $RC on write error: $OUT"
  fails=$((fails + 1))
elif [ "$RC" -eq 0 ]; then
  echo "  FAIL del succeeded despite read-only directory (exit 0)"
  fails=$((fails + 1))
else
  echo "  FAIL del returned unexpected exit $RC: $OUT"
  fails=$((fails + 1))
fi

# restore write access and verify the db is still intact
chmod 755 "$DB/c"
if "$BIN" verify --db "$DB" --coll c >/dev/null 2>&1; then
  echo "  ok   database intact after write errors"
else
  echo "  FAIL database corrupted after write errors"
  fails=$((fails + 1))
fi

# verify the original seed document is still there
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
if [ "$COUNT" -eq 1 ]; then
  echo "  ok   original document survived (count=1)"
else
  echo "  FAIL original document lost (count=$COUNT)"
  fails=$((fails + 1))
fi

rm -rf "$DB"

# --- Part 2: HTTP serve mode with read-only directory ---
PORT="${DISK_FULL_PORT:-4473}"
TOK=dftok
DB=$(mktemp -d /tmp/grange-disk-full-srv-XXXX)

# seed and start server
"$BIN" put --db "$DB" --coll c --id seed --doc '{"v":0}' >/dev/null 2>&1
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 50); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# make the collection directory read-only
chmod 555 "$DB/c"

# attempt a put via HTTP — should get 507, not 500 or crash
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$PORT/put" \
  -H "Authorization: Bearer $TOK" \
  -d '{"coll":"c","id":"x","doc":{"v":1}}' 2>&1)

if [ "$HTTP_CODE" = "507" ]; then
  echo "  ok   HTTP put returns 507 (Insufficient Storage) on write error"
elif [ "$HTTP_CODE" = "500" ]; then
  echo "  FAIL HTTP put returns 500 (should be 507)"
  fails=$((fails + 1))
else
  echo "  FAIL HTTP put returned unexpected $HTTP_CODE"
  fails=$((fails + 1))
fi

# verify server is still alive
if curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1; then
  echo "  ok   server still alive after write error"
else
  echo "  FAIL server crashed after write error"
  fails=$((fails + 1))
fi

# restore and verify
chmod 755 "$DB/c"
curl -s -X POST "http://localhost:$PORT/shutdown" -H "Authorization: Bearer $TOK" >/dev/null 2>&1
sleep 0.3; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

if "$BIN" verify --db "$DB" --coll c >/dev/null 2>&1; then
  echo "  ok   server db intact after write errors"
else
  echo "  FAIL server db corrupted after write errors"
  fails=$((fails + 1))
fi

rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"disk_full":"pass"}'
  exit 0
fi
echo '{"ok":false,"disk_full":"fail","failures":'"$fails"'}'
exit 1
