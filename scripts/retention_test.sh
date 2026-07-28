#!/usr/bin/env bash
# Per-request memory: a long-lived server retains some memory per request (the
# single actor's arena is only reclaimed when the goroutine returns, which it
# never does). That is documented and bounded by the RSS watchdog. What must NOT
# happen is a per-request cost that scales with the COLLECTION.
#
# It did. `gr_count()` was `len(keys(g_mem))`, which materialises every key just
# to count them: an unfiltered /count on a 20k-document collection allocated
# 20k strings and retained 71 kB per request — seven times an INDEXED count.
# Nothing caught it, because every existing harness measures answers, and the
# answer was always right.
#
# So this asserts two things:
#
#   1. an unfiltered count costs about the same on a small and a large
#      collection — the O(n)-per-request shape, caught by comparison rather than
#      by an absolute number
#   2. no route retains more than a ceiling per request
#
# RSS comes from /proc/<pid>/status for the server's OWN pid, captured at
# launch. Matching by name (pgrep -f "grange serve") has bitten this project
# before: the pattern matches the measuring shell too.
set -u
BIN="${1:-./grange}"
PORT="${2:-4482}"
TOK=rettk
A="authorization: Bearer $TOK"
CEILING_KB="${3:-60}"
fails=0

check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

DB=$(mktemp -d /tmp/grange-ret-XXXX); rm -rf "$DB"
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
GRANGE_MAX_RSS_MB=4000 "$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

rss() { awk '/VmRSS/{print $2}' "/proc/$SRV/status" 2>/dev/null || echo 0; }

seed() { # coll n
  python3 -c "
import json
print('\n'.join('k%d\t%s' % (i, json.dumps({'ts': 1785000000+i, 'site': 'a.io' if i%3 else 'b.io'})) for i in range($2)))
" | curl -s -m 300 -X POST "http://localhost:$PORT/bulk?coll=$1" -H "$A" --data-binary @- >/dev/null
  local got
  got=$(curl -s -m 60 "http://localhost:$PORT/count?coll=$1" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
  [ "$got" = "$2" ] || { echo "  FAIL seeding $1: $got docs, expected $2"; fails=$((fails + 1)); }
}

# kb_per_request <label> <path> -> kB retained per request
kb() { local n=300 b a; b=$(rss); for _ in $(seq 1 $n); do curl -s "http://localhost:$PORT$1" -H "$A" >/dev/null; done; a=$(rss); echo $(( (a - b) / n )); }

seed small 1000
seed big 20000
# declare the indexes a real deployment would have: an unindexed clause is a
# SCAN, and a scan legitimately allocates per document it examines. Measuring
# scans here would be measuring the scan, not the per-request overhead.
for c in small big; do
  curl -s -X POST "http://localhost:$PORT/index" -H "$A" -d "{\"coll\":\"$c\",\"field\":\"site\"}" >/dev/null
  curl -s -X POST "http://localhost:$PORT/index" -H "$A" -d "{\"coll\":\"$c\",\"field\":\"ts\",\"kind\":\"range\"}" >/dev/null
done

SMALL=$(kb "/count?coll=small")
BIG=$(kb "/count?coll=big")
echo "  unfiltered count: ${SMALL} kB/request over 1k docs, ${BIG} kB/request over 20k docs"
# 20x the documents must not mean materially more memory per request. 3x is a
# wide margin: the regression this guards against was 7x on 20x the data.
python3 -c "import sys; sys.exit(0 if $BIG <= max(4, $SMALL) * 3 else 1)" \
  && check "an unfiltered count does not scale with collection size" 1 \
  || check "an unfiltered count does not scale with collection size (${SMALL} -> ${BIG} kB)" 0

for probe in "/health" "/count?coll=big&where=site%3Da.io" "/get?coll=big&id=k5" "/find?coll=big&where=site%3Da.io&limit=20" "/find?coll=big&limit=10&order=-ts" "/stats?coll=big"; do
  K=$(kb "$probe")
  [ "$K" -le "$CEILING_KB" ] && check "under ${CEILING_KB}kB/request: $probe (${K}kB)" 1 \
                             || check "under ${CEILING_KB}kB/request: $probe (${K}kB)" 0
done

# and one deliberate SCAN, recorded rather than asserted tightly: it examines
# every document, so its cost is the scan's, not the request loop's. The scan
# budget (GRANGE_MAX_SCAN_DOCS) is what bounds this in production.
SCAN=$(kb "/count?coll=big&where=nosuchfield%3Dx")
echo "  for reference, an unindexed scan of 20k docs: ${SCAN} kB/request"

curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"retention":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
