#!/usr/bin/env bash
# grange backup — copy, verify, prune. Run it from a timer.
#
# A grange database can be backed up with a plain file copy WHILE it is being
# written, and that is a property of the format rather than luck: every .grg
# file is written exactly once and never mutated, a cold run's manifest is
# written LAST, and recovery drops a torn final chunk. So the worst a concurrent
# write can do to a copy is leave a chunk that recovery discards — which is the
# same all-or-nothing commit boundary `make crash` proves.
#
# What makes it a BACKUP rather than a copy is the verification: every copied
# collection is checked with `grange verify`, which walks every file's checksum
# and record stream, a cold manifest against its pages, and the declared indexes.
# It exits 92 when anything is wrong. A backup nobody verified is a hope.
#
#   backup.sh --db /home/dk1/grange/data --out /home/dk1/backups/grange [--keep 7]
set -u
BIN="${GRANGE_BIN:-/home/dk1/grange/grange}"
DB=""
OUT=""
KEEP=7
while [ $# -gt 0 ]; do
  case "$1" in
    --db)   DB="$2"; shift 2 ;;
    --out)  OUT="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --bin)  BIN="$2"; shift 2 ;;
    *) echo "{\"ok\":false,\"error\":\"unknown option: $1\"}"; exit 64 ;;
  esac
done
[ -n "$DB" ] && [ -n "$OUT" ] || { echo '{"ok":false,"error":"usage: backup.sh --db <dir> --out <dir> [--keep N]"}'; exit 64; }
[ -d "$DB" ] || { echo "{\"ok\":false,\"error\":\"no such database: $DB\"}"; exit 66; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$OUT/$STAMP"
NAME=$(basename "$DB")
mkdir -p "$DEST"

# Layout mirrors the source: <stamp>/<name> and <stamp>/<name>.tenants, so a
# restore is a copy back into place with no renaming. The first version put the
# tenant roots BESIDE the stamp directory, which made one backup look like two
# entries to the retention pass — it would have pruned half of a backup.
cp -a "$DB/." "$DEST/$NAME/" 2>/dev/null || { mkdir -p "$DEST/$NAME"; cp -a "$DB/." "$DEST/$NAME/"; }
# tenant databases live in a sibling directory of the admin root, and a backup
# that silently omits every paying tenant is worse than no backup
if [ -d "$DB.tenants" ]; then
  mkdir -p "$DEST/$NAME.tenants"
  cp -a "$DB.tenants/." "$DEST/$NAME.tenants/" 2>/dev/null
fi

checked=0
bad=0
issues=""
# every collection is a directory holding .grg files; verify each one
while IFS= read -r coll; do
  [ -n "$coll" ] || continue
  root=$(dirname "$coll")
  name=$(basename "$coll")
  if "$BIN" verify --db "$root" --coll "$name" >/dev/null 2>&1; then
    checked=$((checked + 1))
  else
    bad=$((bad + 1))
    issues="$issues $root/$name"
    checked=$((checked + 1))
  fi
done < <(find "$DEST" -type d 2>/dev/null | while read -r d; do
           ls "$d"/*.grg >/dev/null 2>&1 && echo "$d"
         done)

BYTES=$(du -sb "$DEST" 2>/dev/null | cut -f1)
if [ "$bad" -gt 0 ]; then
  # keep the bad copy for inspection — deleting the evidence of a failed backup
  # is how you find out about it much later
  echo "{\"ok\":false,\"stamp\":\"$STAMP\",\"collections_checked\":$checked,\"corrupt\":$bad,\"issues\":\"$issues\",\"kept_for_inspection\":\"$DEST\"}"
  exit 92
fi

# prune only AFTER a good backup exists, so a run of failures never leaves the
# retention window empty
if [ "$KEEP" -gt 0 ]; then
  ls -1d "$OUT"/*/ 2>/dev/null | sort | head -n -"$KEEP" | while IFS= read -r old; do
    rm -rf "$old"
  done
fi

KEPT=$(ls -1d "$OUT"/*/ 2>/dev/null | wc -l)
echo "{\"ok\":true,\"stamp\":\"$STAMP\",\"path\":\"$DEST\",\"bytes\":${BYTES:-0},\"collections_verified\":$checked,\"kept\":$KEPT}"
