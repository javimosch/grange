#!/usr/bin/env bash
# Read replicas: 1 writer + N read-only followers over the SAME directory.
#
# `grange serve` is single-actor, so on one server an expensive query is paid
# for by everyone behind it — measured in M31: an 0.2 ms get becomes 85 ms while
# ONE unindexed scan runs. M31 bounded that with scan budgets; it could not
# remove it, and the doc named replicas as the honest next step because the
# mechanism already existed (`serve --follow`, exercised by the replication
# fuzz every gate run).
#
# This asserts the four things a read-replica deployment stands or falls on:
#
#   1. a replica answers the same as the primary
#   2. a replica REFUSES writes (it is not a second writer; two writers on one
#      directory would corrupt it)
#   3. replication lag is small and bounded
#   4. a slow query on one replica does not degrade another, or the primary —
#      the whole point, and the thing a single server cannot do
set -u
BIN="${1:-./grange}"
W="${2:-4470}"      # writer
R1=$((W + 1))
R2=$((W + 2))
TOK=repltk
A="authorization: Bearer $TOK"
N=30000
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

DB=$(mktemp -d /tmp/grange-repl-XXXX); rm -rf "$DB"
fuser -k "$W/tcp" "$R1/tcp" "$R2/tcp" 2>/dev/null; sleep 0.5

up() { for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$1/health" >/dev/null 2>&1 && return; done; }

"$BIN" serve --db "$DB" --port "$W" --token "$TOK" >/tmp/grepl-w.log 2>&1 &
WPID=$!
up "$W"
curl -s -X POST "http://localhost:$W/cold?coll=ev" -H "$A" >/dev/null
python3 -c "
import json
print('\n'.join('k%d\t%s' % (i, json.dumps({'ts': 1785000000+i, 'site': 'a.io' if i%3 else 'b.io'})) for i in range($N)))
" | curl -s -m 300 -X POST "http://localhost:$W/bulk?coll=ev" -H "$A" --data-binary @- >/dev/null
SEEDED=$(curl -s "http://localhost:$W/count?coll=ev" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
[ "$SEEDED" = "$N" ] || { echo "  FAIL seeding: $SEEDED docs, expected $N"; fails=$((fails + 1)); }

# the replicas: same directory, --follow makes them read-only and refresh from
# disk on each request
"$BIN" serve --db "$DB" --port "$R1" --token "$TOK" --follow >/tmp/grepl-r1.log 2>&1 &
R1PID=$!
"$BIN" serve --db "$DB" --port "$R2" --token "$TOK" --follow >/tmp/grepl-r2.log 2>&1 &
R2PID=$!
up "$R1"; up "$R2"

# 1. same answers
PC=$(curl -s "http://localhost:$W/count?coll=ev" -H "$A")
A1=$(curl -s "http://localhost:$R1/count?coll=ev" -H "$A")
A2=$(curl -s "http://localhost:$R2/count?coll=ev" -H "$A")
[ "$PC" = "$A1" ] && [ "$PC" = "$A2" ] && check "replicas answer the same as the primary" 1 \
  || check "replicas answer the same as the primary ($PC | $A1 | $A2)" 0

# 2. and refuse writes. Two writers on one directory would corrupt it, so this
#    is a safety property, not a nicety.
WR=$(curl -s -X POST "http://localhost:$R1/put" -H "$A" -d '{"coll":"ev","id":"nope","doc":{"v":1}}')
echo "$WR" | grep -q "read-only" && check "a replica refuses writes" 1 || check "a replica refuses writes (got: $(echo "$WR" | head -c 80))" 0

# 3. lag: write on the primary, poll a replica until it appears
LAGS=""
for i in 1 2 3; do
  curl -s -X POST "http://localhost:$W/put" -H "$A" -d "{\"coll\":\"ev\",\"id\":\"lag$i\",\"doc\":{\"ts\":1}}" >/dev/null
  t0=$(date +%s%N)
  for _ in $(seq 1 500); do
    curl -s "http://localhost:$R1/get?coll=ev&id=lag$i" -H "$A" | grep -q '"doc"' && break
    sleep 0.01
  done
  t1=$(date +%s%N)
  LAGS="$LAGS $(( (t1 - t0) / 1000000 ))"
done
MAXLAG=$(echo $LAGS | tr ' ' '\n' | sort -rn | head -1)
echo "  replication lag (ms):$LAGS"
[ "$MAXLAG" -lt 1000 ] && check "writes reach a replica in under a second" 1 || check "writes reach a replica in under a second (${MAXLAG}ms)" 0

# 4. the isolation property
ISO=$(python3 - "$W" "$R1" "$R2" "$TOK" <<'PY'
import urllib.request, threading, time, sys
w, r1, r2, tok = sys.argv[1:5]
def req(port, path):
    r = urllib.request.Request(f"http://localhost:{port}{path}")
    r.add_header("authorization", "Bearer " + tok)
    t = time.time()
    try: urllib.request.urlopen(r, timeout=300).read()
    except Exception: pass
    return (time.time() - t) * 1000
def p90(v):
    v = sorted(v); return v[int(len(v) * 0.9) - 1]
idle2 = p90([req(r2, "/get?coll=ev&id=k5") for _ in range(15)])
stop = False
def hammer():
    while not stop: req(r1, "/count?coll=ev&where=site%3Dnope")   # unindexed scan
th = threading.Thread(target=hammer); th.start(); time.sleep(0.5)
busy2 = p90([req(r2, "/get?coll=ev&id=k5") for _ in range(25)])
busyw = p90([req(w,  "/get?coll=ev&id=k5") for _ in range(25)])
busy1 = p90([req(r1, "/get?coll=ev&id=k5") for _ in range(8)])
stop = True; th.join()
print("%.1f %.1f %.1f %.1f" % (idle2, busy2, busyw, busy1))
PY
)
read IDLE2 BUSY2 BUSYW BUSY1 <<< "$ISO"
echo "  a scan looping on replica1 — get p90: replica2 ${BUSY2}ms (idle ${IDLE2}ms), primary ${BUSYW}ms, replica1 ${BUSY1}ms"
# the other replica must be barely affected. 5x the idle figure with a 5ms floor
# is wide enough not to fail on noise, and far below the ~200x a single server
# shows for the same workload.
python3 -c "import sys; sys.exit(0 if $BUSY2 <= max(5.0, $IDLE2 * 5) else 1)" \
  && check "a slow query on one replica does not degrade another" 1 \
  || check "a slow query on one replica does not degrade another (${IDLE2}ms -> ${BUSY2}ms)" 0
python3 -c "import sys; sys.exit(0 if $BUSYW <= max(5.0, $IDLE2 * 5) else 1)" \
  && check "...nor the primary, which stays free to write" 1 \
  || check "...nor the primary (${BUSYW}ms)" 0
# and the replica actually serving it DOES slow down — otherwise the workload
# was not doing anything and the two checks above are vacuous
python3 -c "import sys; sys.exit(0 if $BUSY1 > $BUSY2 else 1)" \
  && check "the replica serving the scan absorbs it (the test is not vacuous)" 1 \
  || check "the replica serving the scan absorbs it (${BUSY1}ms vs ${BUSY2}ms)" 0

for p in "$W" "$R1" "$R2"; do curl -s -X POST "http://localhost:$p/shutdown" -H "$A" >/dev/null 2>&1; done
sleep 0.5; kill "$WPID" "$R1PID" "$R2PID" 2>/dev/null; wait 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"replicas":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
