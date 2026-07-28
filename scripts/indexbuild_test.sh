#!/usr/bin/env bash
# Range-index builds must not be bounded by the collection size.
#
# Building a range index used to collect every (value, id) pair of the field
# into memory before sorting. Measured on 200k documents: RSS 82 MB -> 257 MB,
# and under the hosted 100 MB budget the build SUCCEEDED and then the RSS
# watchdog restarted the process — so one tenant declaring an index took the
# shared server down under every other tenant.
#
# The external sort (spill sorted runs, k-way merge one page at a time, inside a
# scoped arena) replaces it. This harness asserts the two things that matter:
#
#   1. it produces EXACTLY the same index — byte-for-byte, same file names, and
#      leaves no spill files behind. A faster build that answers differently is
#      not a faster build.
#   2. it costs a small fraction of the memory the in-memory path costs, and
#      does not trip a tight RSS budget.
#
# Both paths are run against identical data in the same run, so (2) is a RATIO
# rather than an absolute number and does not depend on the machine.
set -u
BIN="${1:-./grange}"
PORT="${2:-4484}"
# 200k, because at 60k neither path is stressed: both cost 2 MB and the ratio
# assertion below is vacuous. The size has to be one where the old path hurts.
N="${3:-200000}"
TOK=idxtk
A="authorization: Bearer $TOK"
fails=0

check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

python3 -c "
import json
print('\n'.join('e%d\t%s' % (i, json.dumps({'ts': 1785000000 + (i * 7) % 500000, 'site': 'a.io' if i%3 else 'b.io'})) for i in range($N)))
" > /tmp/gidxb.txt

# /bulk caps a request at 50000 ops, so a single POST of the whole fixture is
# REJECTED and the collection stays empty — which makes every measurement below
# read 2 MB and pass a byte-identity check between two empty indexes. That
# happened. seed_docs chunks the load and then ASSERTS THE OBSERVED COUNT, which
# is the only way a seeding bug shows up as a failure instead of a fast pass.
seed_docs() {
  split -l 25000 /tmp/gidxb.txt /tmp/gidxb-part-
  for part in /tmp/gidxb-part-*; do
    curl -s -m 300 -X POST "http://localhost:$PORT/bulk?coll=ev" -H "$A" --data-binary @"$part" >/dev/null
  done
  rm -f /tmp/gidxb-part-*
  local got
  got=$(curl -s -m 60 "http://localhost:$PORT/count?coll=ev" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo 0)
  if [ "$got" != "$N" ]; then
    echo "  FAIL seeding: collection holds $got documents, expected $N"
    fails=$((fails + 1))
  fi
}

# build the same index both ways; report (db dir, rss delta MB)
build() { # external? db budget -> "deltaMB"
  local ext=$1 db=$2 budget=$3
  rm -rf "$db"
  fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
  GRANGE_SORT_EXTERNAL="$ext" GRANGE_MAX_RSS_MB="$budget" "$BIN" serve --db "$db" --port "$PORT" --token "$TOK" >"/tmp/gidxb-$ext.log" 2>&1 &
  for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
  curl -s -X POST "http://localhost:$PORT/cold?coll=ev" -H "$A" >/dev/null
  seed_docs
  local before after
  before=$(curl -s "http://localhost:$PORT/stats?coll=ev" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["rss_kb"]//1024)')
  curl -s -m 600 -X POST "http://localhost:$PORT/index" -H "$A" -d '{"coll":"ev","field":"ts","kind":"range"}' >/dev/null
  after=$(curl -s "http://localhost:$PORT/stats?coll=ev" -H "$A" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["rss_kb"]//1024)' 2>/dev/null || echo 0)
  curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
  sleep 0.5
  echo $((after - before))
}

MEM=$(build 0 /tmp/gidxb-mem 4000)
EXT=$(build 1 /tmp/gidxb-ext 4000)
# a tiny spill size forces many more runs, so the k-way merge is exercised at
# depth rather than with the two or three runs the default produces
SPILL_SAVE="${GRANGE_SORT_SPILL:-}"
export GRANGE_SORT_SPILL=3000
DEEP=$(build 1 /tmp/gidxb-deep 4000)
if [ -n "$SPILL_SAVE" ]; then export GRANGE_SORT_SPILL="$SPILL_SAVE"; else unset GRANGE_SORT_SPILL; fi
echo "  index build RSS delta over $N docs: in-memory ${MEM}MB, external ${EXT}MB"

# 1. identical output
if diff -rq /tmp/gidxb-mem/ev /tmp/gidxb-ext/ev >/dev/null 2>&1; then
  check "external build is byte-identical to the in-memory build" 1
else
  check "external build is byte-identical ($(diff -rq /tmp/gidxb-mem/ev /tmp/gidxb-ext/ev 2>&1 | head -2 | tr '\n' ' '))" 0
fi
if diff -rq /tmp/gidxb-mem/ev /tmp/gidxb-deep/ev >/dev/null 2>&1; then
  check "still identical with 3000-entry spills (many more runs to merge)" 1
else
  check "still identical with 3000-entry spills ($(diff -rq /tmp/gidxb-mem/ev /tmp/gidxb-deep/ev 2>&1 | head -2 | tr '\n' ' '))" 0
fi
LEFT=$(ls /tmp/gidxb-ext/ev 2>/dev/null | grep -c -- "-x" || true)
[ "$LEFT" = "0" ] && check "no spill files left behind" 1 || check "no spill files left behind (found $LEFT)" 0

# 2. materially less memory. 50% is a wide margin against the ~20x measured, so
# this fails on a regression rather than on noise.
python3 -c "import sys; sys.exit(0 if $EXT < $MEM * 0.5 else 1)" \
  && check "external build costs under half the memory" 1 \
  || check "external build costs under half the memory (${EXT}MB vs ${MEM}MB)" 0

# 3. and survives a budget the old path would trip
BUDGET=$(python3 -c "print(max(60, $MEM))")
rm -rf /tmp/gidxb-tight
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
GRANGE_MAX_RSS_MB="$BUDGET" "$BIN" serve --db /tmp/gidxb-tight --port "$PORT" --token "$TOK" >/tmp/gidxb-tight.log 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
curl -s -X POST "http://localhost:$PORT/cold?coll=ev" -H "$A" >/dev/null
seed_docs
curl -s -m 600 -X POST "http://localhost:$PORT/index" -H "$A" -d '{"coll":"ev","field":"ts","kind":"range"}' >/dev/null
sleep 1
RESTARTS=$(grep -c rss_restart /tmp/gidxb-tight.log || true)
ALIVE=$(curl -s -m 5 "http://localhost:$PORT/health" | grep -c '"up"' || true)
[ "$RESTARTS" = "0" ] && [ "$ALIVE" = "1" ] \
  && check "build under a ${BUDGET}MB budget: no watchdog restart, server alive" 1 \
  || check "build under a ${BUDGET}MB budget (restarts=$RESTARTS alive=$ALIVE)" 0
# the index must actually work afterwards
ORD=$(curl -s -m 60 "http://localhost:$PORT/find?coll=ev&limit=3&order=-ts" -H "$A")
echo "$ORD" | grep -q '"mode":"cold-range-ordered"' \
  && check "the index built under that budget answers ordered queries" 1 \
  || check "the index answers ordered queries (got: $(echo "$ORD" | head -c 90))" 0

curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf /tmp/gidxb-mem /tmp/gidxb-ext /tmp/gidxb-deep /tmp/gidxb-tight

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"index_build":"pass","mem_mb":'"$MEM"',"ext_mb":'"$EXT"'}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
