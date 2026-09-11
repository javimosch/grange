#!/usr/bin/env bash
# WAL partial write recovery test.
#
# Simulates a partial WAL write by truncating the last WAL chunk, then verifies
# recovery leaves only committed data: the committed prefix remains, the
# truncated chunk is discarded, and the database remains usable.
#
# grange's WAL chunks are checksummed (.grg format: lines + "#|nrecs|sha12"
# trailer). gr_load_recfile rejects a chunk whose checksum doesn't match, so
# a truncated chunk is silently dropped during recovery — the committed prefix
# (earlier valid chunks) is preserved.
#
# `verify` correctly reports corruption (exit 92) when a chunk is invalid —
# the operator should know. But recovery still works: count, get, and put all
# function with the committed prefix.
set -u
BIN="${1:-./grange}"
fails=0

echo "  WAL partial write recovery:"

DB=$(mktemp -d /tmp/grange-wal-partial-XXXX)

# write 5 documents in separate commits (5 WAL chunks)
"$BIN" put --db "$DB" --coll c --id d1 --doc '{"v":1}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id d2 --doc '{"v":2}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id d3 --doc '{"v":3}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id d4 --doc '{"v":4}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id d5 --doc '{"v":5}' >/dev/null 2>&1

# verify all 5 are present before truncation
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo 0)
if [ "$COUNT" -eq 5 ]; then
  echo "  ok   5 documents written before truncation"
else
  echo "  FAIL expected 5 documents, got $COUNT"
  fails=$((fails + 1))
fi

# find the last WAL chunk
LAST_CHUNK=$(ls "$DB/c"/wal-*.grg 2>/dev/null | sort | tail -1)
if [ -z "$LAST_CHUNK" ]; then
  echo "  FAIL no WAL chunks found"
  fails=$((fails + 1))
  rm -rf "$DB"
  exit 1
fi

# truncate the last chunk — remove the last 20 bytes (breaks the checksum trailer)
ORIG_SIZE=$(wc -c < "$LAST_CHUNK")
TRUNC_SIZE=$((ORIG_SIZE - 20))
if [ "$TRUNC_SIZE" -lt 1 ]; then TRUNC_SIZE=1; fi
truncate -s "$TRUNC_SIZE" "$LAST_CHUNK"
NEW_SIZE=$(wc -c < "$LAST_CHUNK")
echo "  truncated last chunk from $ORIG_SIZE to $NEW_SIZE bytes"

# verify correctly reports corruption (exit 92) — the operator should know
VOUT=$("$BIN" verify --db "$DB" --coll c 2>&1)
VRC=$?
if [ "$VRC" -eq 92 ]; then
  echo "  ok   verify reports corruption (exit 92) — operator is alerted"
else
  echo "  FAIL verify returned exit $VRC (expected 92): $VOUT"
  fails=$((fails + 1))
fi

# but recovery still works — count should be 4 (d5 from truncated chunk is lost)
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
if [ "$COUNT" -eq 4 ]; then
  echo "  ok   committed prefix preserved (count=4, d5 from truncated chunk lost)"
else
  echo "  FAIL expected count=4 after truncation, got $COUNT"
  fails=$((fails + 1))
fi

# verify the committed documents are intact (d1-d4 present, d5 absent)
for id in d1 d2 d3 d4; do
  OUT=$("$BIN" get --db "$DB" --coll c --id "$id" 2>/dev/null)
  if echo "$OUT" | grep -q "\"v\""; then
    echo "  ok   $id present in recovered database"
  else
    echo "  FAIL $id missing from recovered database: $OUT"
    fails=$((fails + 1))
  fi
done

# d5 should be absent (was in the truncated chunk)
D5OUT=$("$BIN" get --db "$DB" --coll c --id d5 2>&1)
D5RC=$?
if [ "$D5RC" -ne 0 ] && echo "$D5OUT" | grep -q 'not-found'; then
  echo "  ok   d5 correctly absent (was in truncated chunk, exit $D5RC)"
else
  echo "  FAIL d5 should be absent (exit=$D5RC): $D5OUT"
  fails=$((fails + 1))
fi

# verify the database is still writable after recovery
"$BIN" put --db "$DB" --coll c --id d6 --doc '{"v":6}' >/dev/null 2>&1
OUT=$("$BIN" get --db "$DB" --coll c --id d6 2>/dev/null)
if echo "$OUT" | grep -q '"v":6'; then
  echo "  ok   database writable after recovery (d6 written and read back)"
else
  echo "  FAIL database not writable after recovery"
  fails=$((fails + 1))
fi

rm -rf "$DB"

# --- Part 2: truncate to 0 bytes (completely empty chunk) ---
DB=$(mktemp -d /tmp/grange-wal-empty-XXXX)
"$BIN" put --db "$DB" --coll c --id d1 --doc '{"v":1}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id d2 --doc '{"v":2}' >/dev/null 2>&1

LAST_CHUNK=$(ls "$DB/c"/wal-*.grg 2>/dev/null | sort | tail -1)
truncate -s 0 "$LAST_CHUNK"

# verify reports corruption, but recovery preserves d1
VRC=$("$BIN" verify --db "$DB" --coll c >/dev/null 2>&1; echo $?)
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
if [ "$VRC" -eq 92 ] && [ "$COUNT" -eq 1 ]; then
  echo "  ok   zero-byte chunk: verify reports corruption (92), recovery preserves d1 (count=1)"
else
  echo "  FAIL zero-byte chunk: verify=$VRC, count=$COUNT (expected 92, 1)"
  fails=$((fails + 1))
fi

rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"wal_partial":"pass"}'
  exit 0
fi
echo '{"ok":false,"wal_partial":"fail","failures":'"$fails"'}'
exit 1
