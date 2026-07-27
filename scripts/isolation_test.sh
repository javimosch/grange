#!/usr/bin/env bash
# Query isolation: does one expensive query still stall everybody else?
#
# `grange serve` runs one request at a time on a single actor. That is a
# correctness choice, not an oversight, but it means one tenant's scan is paid
# for by every other tenant waiting behind it. Measured on a 50k-document cold
# collection: an 0.2 ms get takes ~80 ms while ONE unindexed scan is running.
#
# The scan budget (GRANGE_MAX_SCAN_DOCS / GRANGE_MAX_SCAN_PAGES) bounds that
# blast radius by refusing a query that would hold the actor too long. This
# harness asserts the property that actually matters — the tail latency seen by
# an INNOCENT caller — rather than the budget's own bookkeeping:
#
#   1. with no budget, a fast get's p90 collapses while a scan loops
#   2. with a budget, that p90 stays low (the scan aborts early instead)
#   3. the budget refuses the scan with a message naming the field to index,
#      and does NOT refuse the same query once that index exists
#
# Deliberately compares the two configurations in one run: absolute latency
# depends on the machine, so the assertion is the RATIO between them.
set -u
BIN="${1:-./grange}"
PORT="${2:-4487}"
DB=$(mktemp -d /tmp/grange-isol-XXXX); rm -rf "$DB"
fails=0

python3 -c "
import json
print('\n'.join('e%d\t%s' % (i, json.dumps({'ts': 1785000000+i, 'site': 'a.io' if i%4 else 'b.io', 'kind': 'event'})) for i in range(20000)))
" > /tmp/gisol_batch.txt

start() { # budget
  fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.4
  GRANGE_MAX_SCAN_DOCS="$1" "$BIN" serve --db "$DB" --port "$PORT" --token isoltk >/dev/null 2>&1 &
  for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done
}
stop() { curl -s -X POST "http://localhost:$PORT/shutdown" -H "authorization: Bearer isoltk" >/dev/null 2>&1; sleep 0.5; }

measure() { # -> p90 ms of a fast get while a scan loops
  python3 - "$PORT" <<'PY'
import urllib.request, threading, time, sys
PORT = sys.argv[1]
def req(path):
    r = urllib.request.Request("http://localhost:%s%s" % (PORT, path))
    r.add_header("authorization", "Bearer isoltk")
    t = time.time()
    try: urllib.request.urlopen(r, timeout=300).read()
    except Exception: pass
    return (time.time() - t) * 1000
stop = False
def slow():
    while not stop: req("/count?coll=big&where=kind%3Devent")
th = threading.Thread(target=slow); th.start(); time.sleep(0.3)
lat = sorted(req("/get?coll=small&id=k1") for _ in range(25))
stop = True; th.join()
print("%.1f" % lat[int(len(lat) * 0.9) - 1])
PY
}

check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# load a cold collection once; both runs reuse it
start 0
curl -s -X POST "http://localhost:$PORT/cold?coll=big" -H "authorization: Bearer isoltk" >/dev/null
curl -s -X POST "http://localhost:$PORT/bulk?coll=big" -H "authorization: Bearer isoltk" \
  --data-binary @/tmp/gisol_batch.txt >/dev/null
curl -s -X POST "http://localhost:$PORT/put" -H "authorization: Bearer isoltk" \
  -d '{"coll":"small","id":"k1","doc":{"v":1}}' >/dev/null
UNBOUNDED=$(measure)
stop

start 2000
BOUNDED=$(measure)
ERR=$(curl -s "http://localhost:$PORT/count?coll=big&where=kind%3Devent" -H "authorization: Bearer isoltk")
stop

echo "  p90 of a fast get while a scan loops: ${UNBOUNDED}ms unbounded -> ${BOUNDED}ms budgeted"

# the budget must cut the innocent caller's tail latency by a wide margin. 4x is
# far below the ~25x measured, so this fails on a real regression, not on noise.
python3 -c "import sys; sys.exit(0 if $UNBOUNDED > $BOUNDED * 4 else 1)" \
  && check "budget cuts tail latency >4x" 1 || check "budget cuts tail latency >4x (${UNBOUNDED} vs ${BOUNDED})" 0

echo "$ERR" | grep -q "scan budget" && check "over-budget scan is refused, not silently truncated" 1 \
  || check "over-budget scan is refused (got: $ERR)" 0
echo "$ERR" | grep -q "declare an index on kind" && check "error names the field to index" 1 \
  || check "error names the field to index (got: $ERR)" 0

# and the fix the error suggests must actually work under the same budget
start 2000
curl -s -X POST "http://localhost:$PORT/index" -H "authorization: Bearer isoltk" \
  -d '{"coll":"big","field":"kind"}' >/dev/null
OK=$(curl -s "http://localhost:$PORT/count?coll=big&where=kind%3Devent" -H "authorization: Bearer isoltk")
stop
echo "$OK" | grep -q '"count":20000' && check "the suggested index makes the same query succeed" 1 \
  || check "the suggested index makes the same query succeed (got: $OK)" 0

rm -rf "$DB"
if [ "$fails" -eq 0 ]; then echo '{"ok":true,"isolation":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
