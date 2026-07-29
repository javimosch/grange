#!/usr/bin/env bash
# Field projection: ?fields=a,b must return exactly the full answer reduced to
# those fields — same rows, same order, same values, nothing invented.
#
# The consumer of an agent-first database is usually a model paying per token,
# and until now a caller could say which rows, what order, how many and where to
# resume — but not which FIELDS. Measured on the live analytics mirror (11
# fields per event), asking for the 3 a dashboard needs took 5 rows from 1255
# bytes to 439.
#
# The risk in a change like this is not "does it filter" but "does it filter the
# same way everywhere": projection happens at emit time, and documents are
# emitted from the hot scan, the cold page walk, index resolution, the ordered
# walk and export. So this compares projected-vs-full across all of them, on
# both storage modes.
set -u
BIN="${1:-./grange}"
PORT="${2:-4465}"
TOK=projtk
A="authorization: Bearer $TOK"
N=400
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

DB=$(mktemp -d /tmp/grange-proj-XXXX); rm -rf "$DB"
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
"$BIN" serve --db "$DB" --port "$PORT" --token "$TOK" >/dev/null 2>&1 &
SRV=$!
for _ in $(seq 1 80); do sleep 0.1; curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break; done

python3 -c "
import json
print('\n'.join('k%03d\t%s' % (i, json.dumps({
  'ts': 1785000000 + i,
  'site': 'a.io' if i % 3 else 'b.io',
  'kind': 'pageview',
  'n': i % 50,
  'user': {'id': i % 7, 'name': 'u%d' % (i % 7)},
  'junk': 'x' * 40,
})) for i in range($N)))
" > /tmp/gproj.txt

for c in hot cold; do
  [ "$c" = "cold" ] && curl -s -X POST "http://localhost:$PORT/cold?coll=$c" -H "$A" >/dev/null
  curl -s -m 120 -X POST "http://localhost:$PORT/bulk?coll=$c" -H "$A" --data-binary @/tmp/gproj.txt >/dev/null
  curl -s -X POST "http://localhost:$PORT/index" -H "$A" -d "{\"coll\":\"$c\",\"field\":\"site\"}" >/dev/null
  curl -s -X POST "http://localhost:$PORT/index" -H "$A" -d "{\"coll\":\"$c\",\"field\":\"n\",\"kind\":\"range\"}" >/dev/null
  GOT=$(curl -s "http://localhost:$PORT/count?coll=$c" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])')
  [ "$GOT" = "$N" ] || { echo "  FAIL seeding $c: $GOT docs, expected $N"; fails=$((fails + 1)); }
done

# compare a query with and without ?fields=, reducing the full answer in python
cmp_proj() { # label coll query-suffix fields
  python3 - "$PORT" "$TOK" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, urllib.request
port, tok, label, coll, suffix, fields = sys.argv[1:7]
def get(q):
    r = urllib.request.Request("http://localhost:%s/find?coll=%s&%s" % (port, coll, q))
    r.add_header("authorization", "Bearer " + tok)
    return json.loads(urllib.request.urlopen(r, timeout=120).read())["data"]
full = get(suffix)
proj = get(suffix + "&fields=" + fields)
want = [{"id": i["id"], "doc": {f: i["doc"][f] for f in fields.split(",") if f in i["doc"]}}
        for i in full["items"]]
ok = proj["items"] == want
print("PASS" if ok else "FAIL", label,
      "" if ok else "\n      got  %s\n      want %s" % (proj["items"][:2], want[:2]))
PY
}

for c in hot cold; do
  for probe in "scan:limit=25:ts,site" \
               "indexed:where=site%3Da.io&limit=25:ts,n" \
               "range window:where=n%3E%3D10,n%3C20&limit=25:n" \
               "ordered:limit=25&order=n&desc=1:n,site" \
               "ordered+filter:where=site%3Da.io&limit=25&order=n&desc=1:ts"; do
    label="${probe%%:*}"; rest="${probe#*:}"; q="${rest%%:*}"; f="${rest##*:}"
    R=$(cmp_proj "$c/$label" "$c" "$q" "$f")
    case "$R" in PASS*) check "$c/$label: projected == full reduced" 1 ;;
                 *) check "$(echo "$R" | head -3)" 0 ;; esac
  done
done

# id is always returned, even when not requested
NOID=$(curl -s "http://localhost:$PORT/find?coll=hot&limit=1&fields=ts" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["items"][0].get("id","MISSING"))')
[ "$NOID" != "MISSING" ] && [ -n "$NOID" ] && check "id is returned even when not requested" 1 || check "id is returned even when not requested" 0

# a field the document lacks is OMITTED, not null: grange must not invent structure
MISS=$(curl -s "http://localhost:$PORT/find?coll=hot&limit=1&fields=ts,nosuchfield" -H "$A" | python3 -c '
import json,sys; d=json.load(sys.stdin)["data"]["items"][0]["doc"]; print("null" if "nosuchfield" in d else "omitted")')
[ "$MISS" = "omitted" ] && check "a missing field is omitted, not null" 1 || check "a missing field is omitted, not null (got $MISS)" 0

# nested paths project under their full path, flat
NEST=$(curl -s "http://localhost:$PORT/find?coll=hot&limit=1&fields=user.id" -H "$A" | python3 -c '
import json,sys; d=json.load(sys.stdin)["data"]["items"][0]["doc"]; print("ok" if "user.id" in d else "missing:%s" % list(d))')
[ "$NEST" = "ok" ] && check "a dotted path projects under its full path" 1 || check "a dotted path projects ($NEST)" 0

# projection must not leak into the NEXT request — it is per-query state on a
# single-actor server, which is exactly the shape that leaks if set carelessly
curl -s "http://localhost:$PORT/find?coll=hot&limit=1&fields=ts" -H "$A" >/dev/null
NF=$(curl -s "http://localhost:$PORT/find?coll=hot&limit=1" -H "$A" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["items"][0]["doc"]))')
[ "$NF" -ge 5 ] && check "projection does not leak into the next request" 1 || check "projection leaked: next request returned $NF fields" 0

# paging composes: every page projected, cursor still works
WALK=$(python3 - "$PORT" "$TOK" <<'PY'
import json, sys, urllib.request, urllib.parse
port, tok = sys.argv[1:3]
cur, rows, guard = "", [], 0
while True:
    guard += 1
    if guard > 200: break
    q = "http://localhost:%s/find?coll=cold&limit=37&order=n&desc=1&fields=n" % port
    if cur: q += "&after=" + urllib.parse.quote(cur)
    r = urllib.request.Request(q); r.add_header("authorization", "Bearer " + tok)
    d = json.loads(urllib.request.urlopen(r, timeout=120).read())["data"]
    for i in d["items"]:
        rows.append(i["id"])
        if list(i["doc"]) != ["n"]:
            print("BADSHAPE", list(i["doc"])); sys.exit()
    cur = d.get("next", "")
    if not cur: break
print(len(rows), len(set(rows)))
PY
)
read WN WU <<< "$WALK"
[ "$WN" = "$N" ] && [ "$WU" = "$N" ] && check "projected pages walk every row exactly once" 1 \
  || check "projected pages walk every row exactly once (got $WALK)" 0

# and the payload is actually smaller — the entire point
FULLB=$(curl -s "http://localhost:$PORT/find?coll=cold&limit=50" -H "$A" | wc -c)
PROJB=$(curl -s "http://localhost:$PORT/find?coll=cold&limit=50&fields=ts,site" -H "$A" | wc -c)
echo "  50 rows: ${FULLB} bytes full, ${PROJB} bytes projected to 2 fields"
python3 -c "import sys; sys.exit(0 if $PROJB < $FULLB / 2 else 1)" \
  && check "projection at least halves the payload" 1 \
  || check "projection at least halves the payload ($FULLB -> $PROJB)" 0

curl -s -X POST "http://localhost:$PORT/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$DB"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"projection":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
