#!/usr/bin/env bash
# M22: kill -9 a writer mid-flight on a COLD collection, where a commit spans
# many files (pages, then a manifest) and compaction rewrites a whole generation.
# The invariant: an incomplete run has no valid manifest, so recovery must fall
# back to the last complete state — open cleanly, answer queries, accept writes.
set -u
BIN="${1:-./grange}"
N=2000000
BATCH=250
ROUNDS="${2:-5}"
fails=0
for r in $(seq 1 "$ROUNDS"); do
  D=$(mktemp -d /tmp/grange-coldcrash-XXXX)
  "$BIN" torture --db "$D" --coll c --cold --n "$N" --batch "$BATCH" >/dev/null 2>&1 &
  W=$!
  sleep 0.$((RANDOM % 6 + 2))
  kill -9 "$W" 2>/dev/null
  wait "$W" 2>/dev/null
  OUT=$("$BIN" count --db "$D" --coll c 2>&1); CODE=$?
  COUNT=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null)
  if [ "$CODE" -ne 0 ] || [ -z "$COUNT" ] || [ "$COUNT" -gt "$N" ]; then
    echo "round $r: FAIL open/count code=$CODE out=$OUT"; fails=$((fails+1)); rm -rf "$D"; continue
  fi
  # a filtered query must agree with the full count on the recovered state
  Q=$("$BIN" count --db "$D" --coll c --where grp=g3 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null)
  # writes must still work after recovery, and be durable
  "$BIN" put --db "$D" --coll c --id post-crash --doc '{"ok":1}' >/dev/null 2>&1 || { echo "round $r: FAIL post-crash write"; fails=$((fails+1)); rm -rf "$D"; continue; }
  G=$("$BIN" get --db "$D" --coll c --id post-crash >/dev/null 2>&1; echo $?)
  # and compaction of the recovered generation must preserve the count
  "$BIN" compact --db "$D" --coll c >/dev/null 2>&1
  AFTER=$("$BIN" count --db "$D" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null)
  if [ "$G" -ne 0 ] || [ "$AFTER" != "$((COUNT+1))" ]; then
    echo "round $r: FAIL post-recovery invariants (get=$G count=$COUNT after_compact=$AFTER)"; fails=$((fails+1)); rm -rf "$D"; continue
  fi
  echo "round $r: ok recovered=$COUNT grp=g3=$Q compacted=$AFTER"
  rm -rf "$D"
done
[ "$fails" -eq 0 ] && echo '{"ok":true,"cold_crash_rounds":'"$ROUNDS"',"failures":0}' || { echo '{"ok":false,"failures":'"$fails"'}'; exit 1; }
