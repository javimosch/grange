#!/usr/bin/env bash
# M18 proof: 200k docs — cold collection RAM stays flat vs hot ballooning.
set -e
BIN="${1:-./grange}"
N_BATCHES=20
fuser -k 4487/tcp 2>/dev/null || true
sleep 0.3
D=$(mktemp -d /tmp/grange-cold-XXXX)
trap 'fuser -k 4487/tcp 2>/dev/null || true' EXIT
"$BIN" serve --db "$D" --port 4487 --token tk >/dev/null 2>&1 &
sleep 0.7
A="Authorization: Bearer tk"
curl -s -X POST "localhost:4487/cold?coll=big" -H "$A" >/dev/null
mkbatch() { python3 -c "
import sys
b=int(sys.argv[1])
print('\n'.join(f'k{b*10000+i}\t{{\"i\":{b*10000+i},\"grp\":\"{(b*10000+i)%5}\"}}' for i in range(10000)))" "$1"; }
T0=$(date +%s%N)
for b in $(seq 0 $((N_BATCHES-1))); do mkbatch "$b" | curl -s -X POST "localhost:4487/bulk?coll=big" -H "$A" --data-binary @- >/dev/null; done
T1=$(date +%s%N)
echo "cold ingest 200k: $(( (T1-T0)/1000000 ))ms"
curl -s "localhost:4487/count?coll=big" -H "$A"
curl -s "localhost:4487/get?coll=big&id=k123456" -H "$A" | head -c 80; echo
curl -s -X POST localhost:4487/shutdown -H "$A" >/dev/null || true
sleep 0.5
echo "--- fresh-process footprint (cold, 200k docs) ---"
"$BIN" stats --db "$D" --coll big
T0=$(date +%s%N); "$BIN" get --db "$D" --coll big --id k199999 >/dev/null; T1=$(date +%s%N)
echo "fresh-process cold get: $(( (T1-T0)/1000000 ))ms (incl. process start + open)"
du -sh "$D" | cut -f1 | xargs echo "disk:"
echo "--- hot comparison (same 200k) ---"
"$BIN" serve --db "$D" --port 4487 --token tk >/dev/null 2>&1 &
sleep 0.7
for b in $(seq 0 $((N_BATCHES-1))); do mkbatch "$b" | curl -s -X POST "localhost:4487/bulk?coll=hotbig" -H "$A" --data-binary @- >/dev/null; done
curl -s -X POST localhost:4487/shutdown -H "$A" >/dev/null || true
sleep 0.5
"$BIN" stats --db "$D" --coll hotbig
rm -rf "$D"
