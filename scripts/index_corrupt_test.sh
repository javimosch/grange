#!/usr/bin/env bash
# Index corruption detection test.
#
# Verifies that a corrupted fields.idx file is detected via checksum mismatch,
# the declarations are discarded (queries fall back to scans), and the database
# remains usable.  Also verifies that a valid checksum-protected file loads
# correctly, and that old-format files (without checksum) still load.
set -u
BIN="${1:-./grange}"
fails=0

echo "  index corruption detection:"

# --- Part 1: valid checksum-protected file loads correctly ---
DB=$(mktemp -d /tmp/grange-idx-XXXX)
"$BIN" put --db "$DB" --coll c --id a --doc '{"co":"acme","score":5}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id b --doc '{"co":"globex","score":9}' >/dev/null 2>&1
"$BIN" index --db "$DB" --coll c --field co >/dev/null 2>&1
"$BIN" index --db "$DB" --coll c --field score --range >/dev/null 2>&1

# verify the index file has a checksum trailer
if tail -1 "$DB/c/fields.idx" | grep -q '^#|'; then
  echo "  ok   fields.idx has checksum trailer"
else
  echo "  FAIL fields.idx missing checksum trailer"
  fails=$((fails + 1))
fi

# verify indexes work (ordered find by score)
OUT=$("$BIN" find --db "$DB" --coll c --order score --desc true --limit 10 2>&1)
if echo "$OUT" | grep -q '"id":"b"' && echo "$OUT" | grep -q '"id":"a"'; then
  echo "  ok   indexes work with valid checksum"
else
  echo "  FAIL indexes not working with valid checksum: $OUT"
  fails=$((fails + 1))
fi

rm -rf "$DB"

# --- Part 2: corrupted file is detected and database still works ---
DB=$(mktemp -d /tmp/grange-idx-corrupt-XXXX)
"$BIN" put --db "$DB" --coll c --id a --doc '{"co":"acme","score":5}' >/dev/null 2>&1
"$BIN" put --db "$DB" --coll c --id b --doc '{"co":"globex","score":9}' >/dev/null 2>&1
"$BIN" index --db "$DB" --coll c --field co >/dev/null 2>&1
"$BIN" index --db "$DB" --coll c --field score --range >/dev/null 2>&1

# corrupt the checksum trailer (change the last character)
LAST=$(tail -1 "$DB/c/fields.idx")
CORRUPT_LAST="${LAST%?}X"
head -n -1 "$DB/c/fields.idx" > "$DB/c/fields.idx.tmp"
echo "$CORRUPT_LAST" >> "$DB/c/fields.idx.tmp"
mv "$DB/c/fields.idx.tmp" "$DB/c/fields.idx"

# verify the database still opens and data is accessible (full scan)
OUT=$("$BIN" find --db "$DB" --coll c --limit 10 2>&1)
if echo "$OUT" | grep -q '"id":"a"' && echo "$OUT" | grep -q '"id":"b"'; then
  echo "  ok   data accessible after index corruption (full scan)"
else
  echo "  FAIL data not accessible after index corruption: $OUT"
  fails=$((fails + 1))
fi

# verify count still works
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
if [ "$COUNT" -eq 2 ]; then
  echo "  ok   count works after index corruption (count=2)"
else
  echo "  FAIL count wrong after index corruption (count=$COUNT)"
  fails=$((fails + 1))
fi

# verify the database is still writable
"$BIN" put --db "$DB" --coll c --id c --doc '{"co":"initech","score":7}' >/dev/null 2>&1
COUNT=$("$BIN" count --db "$DB" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
if [ "$COUNT" -eq 3 ]; then
  echo "  ok   database writable after index corruption (count=3)"
else
  echo "  FAIL database not writable after index corruption (count=$COUNT)"
  fails=$((fails + 1))
fi

# verify re-declaring an index works (recovery)
"$BIN" index --db "$DB" --coll c --field score --range >/dev/null 2>&1
OUT=$("$BIN" find --db "$DB" --coll c --order score --desc true --limit 10 2>&1)
if echo "$OUT" | grep -q '"id":"b"'; then
  echo "  ok   index re-declared and works after corruption"
else
  echo "  FAIL index not working after re-declaration: $OUT"
  fails=$((fails + 1))
fi

rm -rf "$DB"

# --- Part 3: old-format file (no checksum) still loads ---
DB=$(mktemp -d /tmp/grange-idx-old-XXXX)
"$BIN" put --db "$DB" --coll c --id a --doc '{"co":"acme","score":5}' >/dev/null 2>&1
"$BIN" index --db "$DB" --coll c --field score --range >/dev/null 2>&1
# strip the checksum trailer to simulate an old-format file
head -n -1 "$DB/c/fields.idx" > "$DB/c/fields.idx.tmp"
mv "$DB/c/fields.idx.tmp" "$DB/c/fields.idx"

OUT=$("$BIN" find --db "$DB" --coll c --order score --desc true --limit 10 2>&1)
if echo "$OUT" | grep -q '"id":"a"'; then
  echo "  ok   old-format fields.idx (no checksum) still loads"
else
  echo "  FAIL old-format fields.idx not loaded: $OUT"
  fails=$((fails + 1))
fi

rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"index_corrupt":"pass"}'
  exit 0
fi
echo '{"ok":false,"index_corrupt":"fail","failures":'"$fails"'}'
exit 1
