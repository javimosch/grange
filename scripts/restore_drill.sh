#!/usr/bin/env bash
# Restore drill — prove the nightly artifact is restorable, on the real host.
#
# `make backup` proves the backup SCRIPT works against a database it just built.
# That is not the same claim as "the artifact sitting on this host right now can
# be restored". A backup nobody has restored from is a hypothesis, and the usual
# way people discover the difference is during an incident.
#
# So this takes the NEWEST backup on the host, restores it into a scratch
# directory, and checks it against the live database — every collection, with
# document counts and an integrity check. It touches nothing live: the restore
# target is a temp directory and the live data is only read.
#
#   restore_drill.sh --backups /home/dk1/backups/grange --live /home/dk1/grange/data
set -u
BIN="${GRANGE_BIN:-/home/dk1/grange/grange}"
BACKUPS=""
LIVE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --backups) BACKUPS="$2"; shift 2 ;;
    --live) LIVE="$2"; shift 2 ;;
    --bin) BIN="$2"; shift 2 ;;
    *) echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
  esac
done
[ -n "$BACKUPS" ] && [ -n "$LIVE" ] || { echo '{"ok":false,"error":"usage: restore_drill.sh --backups <dir> --live <db>"}'; exit 64; }

NEWEST=$(ls -1d "$BACKUPS"/*/ 2>/dev/null | sort | tail -1)
[ -n "$NEWEST" ] || { echo "{\"ok\":false,\"error\":\"no backups under $BACKUPS\"}"; exit 66; }
BSTAMP=$(stat -c %Y "$NEWEST")
AGE_H=$(( ( $(date +%s) - BSTAMP ) / 3600 ))

# Anything CREATED AFTER the backup ran is expected to be absent from it, and
# reporting that as a failure makes the drill cry wolf: the first run flagged a
# tenant that had been signed up twenty minutes earlier. Compare against what
# existed when the artifact was taken.
newer_than_backup() {
  [ -e "$1" ] || return 1
  [ "$(stat -c %Y "$1")" -gt "$BSTAMP" ]
}

WORK=$(mktemp -d /tmp/grange-drill-XXXX)
NAME=$(basename "$LIVE")
cp -a "$NEWEST." "$WORK/" 2>/dev/null
REST="$WORK/$NAME"
[ -d "$REST" ] || { echo "{\"ok\":false,\"error\":\"backup has no $NAME directory: $(ls "$WORK" | tr '\n' ' ')\"}"; rm -rf "$WORK"; exit 65; }

# compare every collection that exists in BOTH, and report ones only in the live
# database (a backup missing a collection is the failure that matters)
issues=""
checked=0
missing=""
drift=""
for live_coll in "$LIVE"/*/; do
  [ -d "$live_coll" ] || continue
  c=$(basename "$live_coll")
  case "$c" in _sys) continue ;; esac
  ls "$live_coll"/*.grg >/dev/null 2>&1 || continue
  if [ ! -d "$REST/$c" ]; then
    newer_than_backup "$live_coll" && continue   # created after the artifact
    missing="$missing $c"
    continue
  fi
  checked=$((checked + 1))
  LC=$("$BIN" count --db "$LIVE" --coll "$c" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
  RC=$("$BIN" count --db "$REST" --coll "$c" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
  "$BIN" verify --db "$REST" --coll "$c" >/dev/null 2>&1 || issues="$issues $c"
  # the restore may legitimately hold FEWER documents (writes since the backup),
  # never more — more would mean the artifact is not a prefix of this database
  if [ "$RC" -gt "$LC" ] 2>/dev/null; then drift="$drift $c(restored=$RC>live=$LC)"; fi
  if [ "$RC" -lt 0 ] || [ "$LC" -lt 0 ]; then drift="$drift $c(unreadable)"; fi
done

# tenant databases: the ones that are somebody's paid data
tchecked=0
tmissing=""
if [ -d "$LIVE.tenants" ]; then
  for tdb in "$LIVE.tenants"/*/*/; do
    [ -d "$tdb" ] || continue
    rel=${tdb#"$LIVE.tenants/"}
    if [ ! -d "$REST.tenants/$rel" ]; then
      newer_than_backup "$tdb" && continue       # tenant signed up after the artifact
      tmissing="$tmissing $rel"
      continue
    fi
    for tc in "$tdb"*/; do
      [ -d "$tc" ] || continue
      cn=$(basename "$tc")
      ls "$tc"/*.grg >/dev/null 2>&1 || continue
      tchecked=$((tchecked + 1))
      LC=$("$BIN" count --db "${tdb%/}" --coll "$cn" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
      RC=$("$BIN" count --db "$REST.tenants/${rel%/}" --coll "$cn" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo -1)
      "$BIN" verify --db "$REST.tenants/${rel%/}" --coll "$cn" >/dev/null 2>&1 || issues="$issues ${rel}${cn}"
      if [ "$RC" -gt "$LC" ] 2>/dev/null; then drift="$drift ${rel}${cn}(restored=$RC>live=$LC)"; fi
      if [ "$RC" -lt 0 ] || [ "$LC" -lt 0 ]; then drift="$drift ${rel}${cn}(unreadable)"; fi
    done
  done
fi

# a restored database must also be WRITABLE — restoring into a museum piece is
# not a recovery
"$BIN" put --db "$REST" --coll drill --doc '{"drill":1}' >/dev/null 2>&1
WOK=$("$BIN" count --db "$REST" --coll drill 2>/dev/null | grep -c '"count":1' || true)

rm -rf "$WORK"

FAIL=0
[ -n "$issues" ] && FAIL=1
[ -n "$drift" ] && FAIL=1
[ -n "$missing" ] && FAIL=1
[ -n "$tmissing" ] && FAIL=1
[ "$WOK" = "1" ] || FAIL=1

printf '{"ok":%s,"backup":"%s","age_hours":%s,"admin_collections_checked":%s,"tenant_collections_checked":%s,"writable_after_restore":%s' \
  "$([ "$FAIL" = "0" ] && echo true || echo false)" "$(basename "$NEWEST")" "$AGE_H" "$checked" "$tchecked" "$([ "$WOK" = "1" ] && echo true || echo false)"
[ -n "$missing" ] && printf ',"collections_absent_from_backup":"%s"' "$missing"
[ -n "$tmissing" ] && printf ',"tenant_dbs_absent_from_backup":"%s"' "$tmissing"
[ -n "$issues" ] && printf ',"integrity_issues":"%s"' "$issues"
[ -n "$drift" ] && printf ',"count_drift":"%s"' "$drift"
printf '}\n'
exit "$FAIL"
