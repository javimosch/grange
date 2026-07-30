#!/usr/bin/env bash
# Backup and restore, under concurrent writes.
#
# grange's release notes have claimed "nightly backups" since v0.9.0. There were
# none — no timer, no cron, no backup directory on the host. The capability did
# not exist, which is the worst kind of production gap: the one everybody
# believes is covered.
#
# The claim this harness makes is narrow and checkable: a plain file copy taken
# WHILE the database is being written is a valid backup, because every .grg file
# is written once and never mutated, manifests are written last, and recovery
# drops a torn final chunk. So a copy can lose the in-flight commit, and nothing
# else.
#
# Asserted here:
#   1. a backup taken during continuous writes verifies clean
#   2. restoring it yields a readable database holding a COMMITTED PREFIX —
#      never more than the source had, never a partial document
#   3. the restored copy is writable (it is a database, not a museum piece)
#   4. tenant databases are included — they are the paying customers, and they
#      live in a sibling directory the obvious `cp -a $DB` would miss
#   5. a CORRUPT backup is reported and kept, not silently pruned
set -u
BIN="${1:-./grange}"
PORT="${2:-4463}"
TOK=baktk
A="authorization: Bearer $TOK"
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

WORK=$(mktemp -d /tmp/grange-bak-XXXX)
DB="$WORK/db"
OUT="$WORK/backups"
mkdir -p "$OUT"
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >"$WORK/log" 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

# a tenant, so the backup has to reach beyond the admin root
TT=$(curl -s -X POST "http://localhost:$PORT/tenants" -H "X-Peage-Wallet: pw_bak" -d '{}' \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])' 2>/dev/null || echo "")
if [ -n "$TT" ]; then
  curl -s -X POST "http://localhost:$PORT/put" -H "authorization: Bearer $TT" \
    -d '{"db":"appdb","coll":"leads","id":"t1","doc":{"co":"acme"}}' >/dev/null
fi

curl -s -X POST "http://localhost:$PORT/put" -H "$A" -d '{"coll":"c","id":"seed","doc":{"v":0}}' >/dev/null

# write continuously while the backup runs — the whole point
stop_writer=0
( i=0
  while [ ! -f "$WORK/stop" ]; do
    curl -s -X POST "http://localhost:$PORT/put" -H "$A" -d "{\"coll\":\"c\",\"id\":\"k$i\",\"doc\":{\"v\":$i}}" >/dev/null 2>&1
    i=$((i + 1))
  done ) &
WPID=$!
sleep 1.5

OUTPUT=$("$(dirname "$0")/backup.sh" --bin "$BIN" --db "$DB" --out "$OUT" --keep 3 2>&1)
RC=$?
touch "$WORK/stop"; sleep 0.5; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null

echo "  backup: $(echo "$OUTPUT" | head -c 150)"
[ "$RC" = "0" ] && check "a backup taken during continuous writes verifies clean" 1 \
                || check "a backup taken during continuous writes verifies clean (rc=$RC)" 0

STAMP=$(echo "$OUTPUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stamp",""))' 2>/dev/null || echo "")
REST="$OUT/$STAMP"
[ -d "$REST" ] && check "the backup directory exists" 1 || check "the backup directory exists" 0

# 2. the restored copy holds a committed prefix, no more than the source
SRC=$(curl -s "http://localhost:$PORT/count?coll=c" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
RESTORED=$("$BIN" count --db "$REST/db" --coll c 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
echo "  source has $SRC documents, the restored backup has $RESTORED"
python3 -c "import sys; sys.exit(0 if 0 < $RESTORED <= $SRC else 1)" \
  && check "restored holds a committed prefix (never more than the source)" 1 \
  || check "restored holds a committed prefix (src=$SRC restored=$RESTORED)" 0

# every restored document must be intact, not truncated
BAD=$("$BIN" find --db "$REST/db" --coll c --limit 100000 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
print(sum(1 for i in d["items"] if not isinstance(i.get("doc"),dict) or "v" not in i["doc"]))' 2>/dev/null || echo -1)
[ "$BAD" = "0" ] && check "every restored document is whole" 1 || check "every restored document is whole ($BAD malformed)" 0

# 3. a restored database is writable
"$BIN" put --db "$REST/db" --coll c --id afterrestore --doc '{"v":999}' >/dev/null 2>&1
AFTER=$("$BIN" get --db "$REST/db" --coll c --id afterrestore 2>/dev/null | grep -c '"v"' || true)
[ "$AFTER" = "1" ] && check "a restored database accepts writes" 1 || check "a restored database accepts writes" 0

# 4. tenant data is in the backup
if [ -n "$TT" ]; then
  if ls -d "$REST"/db.tenants/*/appdb/leads >/dev/null 2>&1; then
    TC=$("$BIN" count --db "$(ls -d "$REST"/db.tenants/*/appdb)" --coll leads 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo 0)
    [ "$TC" = "1" ] && check "tenant databases are backed up and readable" 1 || check "tenant databases are backed up (count=$TC)" 0
  else
    check "tenant databases are backed up (nothing under $REST/db.tenants)" 0
  fi
fi

# 5. a corrupt backup must be REPORTED and KEPT, not pruned away
curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
CORRUPT="$WORK/corruptsrc"
cp -a "$DB" "$CORRUPT"
victim=$(ls "$CORRUPT"/c/*.grg 2>/dev/null | head -1)
printf 'garbage' >> "$victim"
OUT2="$WORK/backups2"; mkdir -p "$OUT2"
BADOUT=$("$(dirname "$0")/backup.sh" --bin "$BIN" --db "$CORRUPT" --out "$OUT2" --keep 3 2>&1)
BRC=$?
[ "$BRC" = "92" ] && check "a corrupt source is reported (exit 92), not called a backup" 1 \
                  || check "a corrupt source is reported (got exit $BRC: $(echo "$BADOUT" | head -c 90))" 0
echo "$BADOUT" | grep -q kept_for_inspection && check "the failed backup is kept for inspection" 1 \
                                             || check "the failed backup is kept for inspection" 0

# the backup must record its success where /ready can see it: a job that stops
# running is invisible otherwise, which is exactly how "nightly backups" stayed
# in the release notes for eleven days with no backups at all
[ -f "$DB/.last_backup" ] && check "a successful backup records a marker for /ready" 1 \
  || check "a successful backup records a marker for /ready" 0

ENTRIES=$(ls -1d "$OUT"/*/ 2>/dev/null | wc -l)
[ "$ENTRIES" = "1" ] && check "one backup is one retention entry" 1 \
  || check "one backup is one retention entry (found $ENTRIES: $(ls -1 "$OUT" | tr '\n' ' '))" 0

rm -rf "$WORK"
if [ "$fails" -eq 0 ]; then echo '{"ok":true,"backup":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
