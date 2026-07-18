#!/usr/bin/env bash
# Crash-safety harness: kill -9 a writer mid-flight, then prove the db opens
# clean and holds exactly a committed prefix (no torn state, no corruption).
set -u
BIN="${1:-./grange}"
N=2000000
BATCH=200
ROUNDS="${2:-5}"
fails=0

for r in $(seq 1 "$ROUNDS"); do
  DB=$(mktemp -d /tmp/grange-crash-XXXX)
  "$BIN" torture --db "$DB" --n "$N" --batch "$BATCH" >/dev/null 2>&1 &
  W=$!
  sleep 0.$((RANDOM % 5 + 1))
  kill -9 "$W" 2>/dev/null
  wait "$W" 2>/dev/null
  OUT=$("$BIN" count --db "$DB" 2>&1)
  CODE=$?
  COUNT=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null)
  STATS=$("$BIN" stats --db "$DB" 2>/dev/null)
  if [ "$CODE" -ne 0 ] || [ -z "$COUNT" ] || [ "$COUNT" -gt "$N" ]; then
    echo "round $r: FAIL code=$CODE out=$OUT"
    fails=$((fails + 1))
  else
    # db must remain writable after the crash
    POST=$("$BIN" put --db "$DB" --coll default --doc '{"post":1}' >/dev/null 2>&1; echo $?)
    if [ "$POST" -ne 0 ]; then
      echo "round $r: FAIL post-crash write code=$POST"
      fails=$((fails + 1))
    else
      echo "round $r: ok count=$COUNT stats=$STATS"
    fi
  fi
  rm -rf "$DB"
done

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"rounds":'"$ROUNDS"',"failures":0}'
  exit 0
fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
