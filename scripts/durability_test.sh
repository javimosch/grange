#!/usr/bin/env bash
# Durability discipline, asserted at the syscall level.
#
# `make crash` proves PROCESS-crash safety (kill -9), which the page cache
# survives on its own — it says nothing about a power cut or a kernel panic.
# That needs fsync, and fsync is invisible to every behavioural test: a build
# that silently dropped it would pass the whole rest of the gate.
#
# So this traces the real syscalls and asserts the ordering a durable commit
# depends on:
#
#   1. a commit fsyncs its WAL chunk, and then fsyncs the DIRECTORY (creating
#      the chunk is a directory change; without that sync a fully-synced file
#      can still vanish after a crash)
#   2. on a cold flush, every page is fsynced BEFORE the manifest that names it
#      is — manifest-last is only meaningful if the ordering is real on disk
#   3. GRANGE_FSYNC=0 issues none of them (the documented opt-out really opts
#      out, so the measured cost below is the cost of durability)
#
# What this does NOT prove: that the DEVICE honours fsync. Consumer drives with
# volatile write caches can lie. That is a hardware property, not something a
# test on this box can establish, and the README says so.
set -u
BIN="${1:-./grange}"
fails=0

command -v strace >/dev/null 2>&1 || { echo '{"ok":false,"error":"strace not installed"}'; exit 1; }

trace() { # tracefile db-dir -- cmd...
  local out=$1; shift
  strace -f -e trace=openat,fsync,unlink,unlinkat -o "$out" "$@" >/dev/null 2>&1
}

# resolve fsync(fd) back to the path that fd was opened with
parse() {
  python3 - "$1" <<'PY'
import re, sys
fds, order = {}, []
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r'openat\([^,]+, "([^"]+)"[^)]*\)\s*=\s*(\d+)', line)
    if m:
        fds[m.group(2)] = m.group(1)
        continue
    m = re.search(r'fsync\((\d+)\)', line)
    if m:
        order.append(fds.get(m.group(1), "?"))
print("\n".join(order))
PY
}

check() { # label condition-result
  if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi
}

echo "1. commit: chunk fsynced, then directory fsynced"
DB=$(mktemp -d /tmp/grange-dur-XXXX); rm -rf "$DB"
trace /tmp/gdur1.txt "$BIN" put --db "$DB" --coll c --doc '{"v":1}'
SYNCS=$(parse /tmp/gdur1.txt)
echo "$SYNCS" | grep -q "wal-000000-000000.grg" && check "wal chunk is fsynced" 1 || check "wal chunk is fsynced" 0
# the directory sync must come after the chunk sync
CHUNK_AT=$(echo "$SYNCS" | grep -n "wal-.*grg" | head -1 | cut -d: -f1)
DIR_AT=$(echo "$SYNCS" | grep -n "/c$" | head -1 | cut -d: -f1)
if [ -n "$CHUNK_AT" ] && [ -n "$DIR_AT" ] && [ "$DIR_AT" -gt "$CHUNK_AT" ]; then
  check "directory fsynced after the chunk" 1
else
  check "directory fsynced after the chunk (chunk@${CHUNK_AT:-none} dir@${DIR_AT:-none})" 0
fi
rm -rf "$DB"

echo "2. cold flush: pages fsynced before the manifest that names them"
# cold and bulk are server-only routes, so this traces the server process.
DB=$(mktemp -d /tmp/grange-dur-XXXX); rm -rf "$DB"
PORT=4496
python3 -c "print('\n'.join('k%d\t{\"v\":%d}' % (i, i) for i in range(3000)))" > /tmp/gdur_batch.txt
strace -f -e trace=openat,fsync -o /tmp/gdur2.txt \
  "$BIN" serve --db "$DB" --port "$PORT" --token durtk >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
curl -s -X POST "http://localhost:$PORT/cold?coll=c" -H "authorization: Bearer durtk" >/dev/null
curl -s -X POST "http://localhost:$PORT/bulk?coll=c" -H "authorization: Bearer durtk" \
  --data-binary @/tmp/gdur_batch.txt >/dev/null
curl -s -X POST "http://localhost:$PORT/shutdown" -H "authorization: Bearer durtk" >/dev/null 2>&1
sleep 1; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
SYNCS=$(parse /tmp/gdur2.txt)
PAGE_LAST=$(echo "$SYNCS" | grep -n "crun-.*-p[0-9]*\.grg" | tail -1 | cut -d: -f1)
META_AT=$(echo "$SYNCS" | grep -n "\.cmeta" | head -1 | cut -d: -f1)
if [ -n "$PAGE_LAST" ] && [ -n "$META_AT" ] && [ "$META_AT" -gt "$PAGE_LAST" ]; then
  check "every page fsynced before the manifest" 1
else
  check "every page fsynced before the manifest (last page@${PAGE_LAST:-none} manifest@${META_AT:-none})" 0
fi
rm -rf "$DB"

echo "3. GRANGE_FSYNC=0 issues no fsync at all"
DB=$(mktemp -d /tmp/grange-dur-XXXX); rm -rf "$DB"
GRANGE_FSYNC=0 trace /tmp/gdur3.txt "$BIN" put --db "$DB" --coll c --doc '{"v":1}'
N=$(parse /tmp/gdur3.txt | grep -c . || true)
[ "$N" = "0" ] && check "opt-out issues zero fsyncs" 1 || check "opt-out issues zero fsyncs (got $N)" 0
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then
  echo '{"ok":true,"durability_checks":"pass"}'
  exit 0
fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
