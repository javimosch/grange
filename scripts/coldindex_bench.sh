#!/usr/bin/env bash
# M20 proof: cold-index lookups vs full cold scans, 100k docs on disk.
set -u
BIN="${1:-./grange}"
N=100000
fuser -k 4481/tcp 2>/dev/null || true
sleep 0.3
D=$(mktemp -d /tmp/grange-cix-XXXX)
trap 'fuser -k 4481/tcp 2>/dev/null || true; rm -rf "$D"' EXIT
"$BIN" serve --db "$D" --port 4481 --token tk >"$D/log" 2>&1 &
SRV=$!
sleep 0.7
A="Authorization: Bearer tk"
curl -s -X POST "localhost:4481/cold?coll=big" -H "$A" >/dev/null
for b in $(seq 0 9); do
  python3 -c "
import sys
b=int(sys.argv[1])
print('\n'.join(f'k{b*10000+i}\t{{\"i\":{b*10000+i},\"grp\":\"g{(b*10000+i)%50}\",\"email\":\"u{b*10000+i}@x.io\"}}' for i in range(10000)))" "$b" \
  | curl -s -X POST "localhost:4481/bulk?coll=big" -H "$A" --data-binary @- | grep -q '"ok":true' || { echo "FAIL bulk batch $b"; exit 1; }
done
COUNT=$(curl -s "localhost:4481/count?coll=big" -H "$A" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['count'])")
echo "loaded: $COUNT docs · $(du -sh "$D/big" | cut -f1) on disk"
bench() { # $1 label, $2 query
  T=0
  for i in 1 2 3 4 5; do
    S=$(date +%s%N); OUT=$(curl -s "localhost:4481/find?coll=big&$2" -H "$A"); E=$(date +%s%N)
    T=$((T + (E-S)/1000000))
  done
  echo "$1: $((T/5))ms avg · $(echo "$OUT" | python3 -c "import json,sys; d=json.load(sys.stdin)['data']; print('mode='+d['mode'], 'hits='+str(d['count']))")"
}
bench "unique lookup, NO index " "where=email%3Du77777%40x.io"
bench "group lookup,  NO index " "where=grp%3Dg7&limit=2000"
S=$(date +%s%N); curl -s -X POST "localhost:4481/index?coll=big" -H "$A" -d '{"field":"email"}' >/dev/null
curl -s -X POST "localhost:4481/index?coll=big" -H "$A" -d '{"field":"grp"}' >/dev/null; E=$(date +%s%N)
echo "index build (2 fields, ${COUNT} docs): $(( (E-S)/1000000 ))ms · $(du -sh "$D/big" | cut -f1) on disk"
bench "unique lookup, INDEXED   " "where=email%3Du77777%40x.io"
bench "group lookup,  INDEXED   " "where=grp%3Dg7&limit=2000"
# the server reports its own RSS: matching PIDs by command line is unreliable
RSS=$(curl -s "localhost:4481/stats?coll=big" -H "$A" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['rss_kb'])")
echo "server-reported RSS after the whole run: $((RSS/1024))MB"
curl -s -X POST localhost:4481/shutdown -H "$A" >/dev/null || true
