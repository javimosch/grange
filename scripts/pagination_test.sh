#!/usr/bin/env bash
# Keyset pagination: walking a collection page by page must yield exactly the
# same sequence as asking for it all at once — every document once, in order.
#
# The interesting case is TIES. A cursor is a (value, id) pair, and a page
# boundary falling in the middle of a run of equal values is precisely where a
# value-only cursor loses documents or repeats them. So the fixture gives many
# documents the same sort value, with page sizes chosen to land inside those
# runs, on both storage modes and both directions.
#
# The assertion is the strong one: concatenated pages == the one-shot ordered
# list, compared element by element, not just by count.
set -u
BIN="${1:-./grange}"
PORT="${2:-4486}"
DB=$(mktemp -d /tmp/grange-page-XXXX); rm -rf "$DB"
TOK=pagetk
A="authorization: Bearer $TOK"
N=300
fails=0

fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# ties: v takes only N/4 distinct values, so runs of equal keys are ~4 long and
# page boundaries of size 7 and 13 land inside them
python3 -c "
import json
print('\n'.join('k%03d\t%s' % (i, json.dumps({'v': i // 4, 'grp': 'g%d' % (i % 3)})) for i in range($N)))
" > /tmp/gpage.txt

for c in hot cold; do
  [ "$c" = "cold" ] && curl -s -X POST "http://localhost:$PORT/cold?coll=$c" -H "$A" >/dev/null
  curl -s -m 60 -X POST "http://localhost:$PORT/bulk?coll=$c" -H "$A" --data-binary @/tmp/gpage.txt >/dev/null
  curl -s -X POST "http://localhost:$PORT/index" -H "$A" -d "{\"coll\":\"$c\",\"field\":\"v\",\"kind\":\"range\"}" >/dev/null
done

walk() { # coll dir pagesize where -> ids, one per line
  python3 - "$PORT" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, urllib.request, urllib.parse
port, coll, direction, size, where = sys.argv[1:6]
def get(url):
    r = urllib.request.Request(url); r.add_header("authorization", "Bearer pagetk")
    return json.loads(urllib.request.urlopen(r, timeout=60).read())["data"]
cur, out, guard = "", [], 0
while True:
    guard += 1
    if guard > 500: print("RUNAWAY", file=sys.stderr); break
    q = (f"http://localhost:{port}/find?coll={coll}&limit={size}&order=v"
         f"&where={urllib.parse.quote(where)}")
    if direction == "desc": q += "&desc=1"
    if cur: q += "&after=" + urllib.parse.quote(cur)
    d = get(q)
    out += [i["id"] for i in d["items"]]
    cur = d.get("next", "")
    if not cur: break
print("\n".join(out))
PY
}

oneshot() { # coll dir where -> ids
  python3 - "$PORT" "$1" "$2" "$3" <<'PY'
import json, sys, urllib.request, urllib.parse
port, coll, direction, where = sys.argv[1:5]
q = (f"http://localhost:{port}/find?coll={coll}&limit=100000&order=v"
     f"&where={urllib.parse.quote(where)}")
if direction == "desc": q += "&desc=1"
r = urllib.request.Request(q); r.add_header("authorization", "Bearer pagetk")
d = json.loads(urllib.request.urlopen(r, timeout=120).read())["data"]
print("\n".join(i["id"] for i in d["items"]))
PY
}

compare() { # label paged oneshot
  local label=$1 paged=$2 whole=$3
  if [ "$paged" = "$whole" ]; then
    check "$label" 1
    return
  fi
  local np nw dup
  np=$(echo "$paged" | grep -c .); nw=$(echo "$whole" | grep -c .)
  dup=$(echo "$paged" | sort | uniq -d | head -3 | tr '\n' ' ')
  miss=$(comm -13 <(echo "$paged" | sort) <(echo "$whole" | sort) | head -3 | tr '\n' ' ')
  check "$label — paged=$np oneshot=$nw dups=[${dup:-none}] missing=[${miss:-none}]" 0
}

for c in hot cold; do
  for d in asc desc; do
    for sz in 7 13; do
      compare "$c/$d: pages of $sz reproduce the full order" "$(walk "$c" "$d" "$sz" "")" "$(oneshot "$c" "$d" "")"
    done
    # with a filter, so pages are not aligned to the underlying key order
    compare "$c/$d: pages of 5 with a where-clause" "$(walk "$c" "$d" 5 "grp=g1")" "$(oneshot "$c" "$d" "grp=g1")"
    # and inside a window, where the span itself is bounded
    compare "$c/$d: pages of 9 inside a window" "$(walk "$c" "$d" 9 "v>=10,v<60")" "$(oneshot "$c" "$d" "v>=10,v<60")"
  done
done

# every document exactly once, counted independently of the one-shot oracle
GOT=$(walk hot asc 7 "" | sort -u | grep -c .)
[ "$GOT" = "$N" ] && check "every one of $N documents returned exactly once" 1 \
                  || check "every one of $N documents returned exactly once (got $GOT unique)" 0

curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"pagination":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
