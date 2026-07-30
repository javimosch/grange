#!/usr/bin/env bash
# `field=a|b|c` — alternatives, i.e. an IN clause.
#
# `where` was AND-only: every clause narrowed, nothing widened, so "status is
# active OR pending" was not expressible and callers were resolving it with two
# round trips and a client-side merge. This adds alternatives on an equality
# clause, which is the shape people actually mean when they ask for OR.
#
# It is NOT arbitrary boolean OR across different fields. That needs an
# expression tree and would change how clauses combine; alternatives cannot be
# confused with the comma that already means AND, and — the reason this shape was
# chosen — each alternative stays an exact index lookup, so the clause is served
# as a UNION of buckets instead of degrading into a scan.
#
# Both storage layers are tested because they are DIFFERENT index
# implementations: the hot path reads in-memory buckets, cold reads
# hash-partitioned index pages off disk. The first version of this change worked
# on the hot path and silently answered 0 on cold.
#
# Every count below is asserted against an independently computed expectation,
# not against whatever the binary happens to say.
set -u
BIN="${BIN:-./grange}"
PORT="${PORT:-4489}"
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

D=$(mktemp -d /tmp/grange-in-XXXX)
fuser -k "$PORT/tcp" 2>/dev/null; sleep 0.3
GRANGE_TOKEN=intk "$BIN" serve --db "$D/db" --port "$PORT" --token intk >"$D/log" 2>&1 &
SRV=$!
B="http://localhost:$PORT"
A="authorization: Bearer intk"
for _ in $(seq 1 80); do sleep 0.1; curl -sf "$B/health" >/dev/null 2>&1 && break; done

# 4000 docs, 4 statuses round-robin: exactly 1000 of each, ts strictly increasing
gen() { python3 -c "
import json
for i in range(4000):
    print('k%d\t%s' % (i, json.dumps({'status':['active','pending','done','closed'][i%4],'ts':1785000000+i})))"; }

# cnt <coll> <where> -> \"count mode scanned\"
cnt() { curl -s -m 40 "$B/count?coll=$1&where=$2" -H "$A" \
        | python3 -c 'import json,sys
d=json.load(sys.stdin).get("data",{})
print(d.get("count","ERR"), d.get("mode","-"), d.get("scanned","-"))' 2>/dev/null || echo "ERR - -"; }

for layer in hot cold; do
  C="c$layer"
  [ "$layer" = "cold" ] && curl -s -m 20 -X POST "$B/cold?coll=$C" -H "$A" >/dev/null
  gen | curl -s -m 120 -X POST "$B/bulk?coll=$C" -H "$A" --data-binary @- >/dev/null
  N=$(curl -s -m 20 "$B/count?coll=$C" -H "$A" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["count"])' 2>/dev/null || echo 0)
  # assert the OBSERVED load: a harness that indexes an empty collection passes
  # in seconds while proving nothing, which has happened here before
  [ "$N" = "4000" ] && check "$layer: 4000 documents loaded" 1 || check "$layer: expected 4000 documents, got $N" 0
  curl -s -m 90 -X POST "$B/index" -H "$A" -d "{\"coll\":\"$C\",\"field\":\"status\"}" >/dev/null
  curl -s -m 90 -X POST "$B/index" -H "$A" -d "{\"coll\":\"$C\",\"field\":\"ts\",\"kind\":\"range\"}" >/dev/null

  set -- \
    "status=active|1000|one value still works" \
    "status=active%7Cpending|2000|two alternatives are the union" \
    "status=active%7Cpending%7Cdone|3000|three alternatives" \
    "status=zzz%7Cactive|1000|an alternative that matches nothing is ignored" \
    "status=zzz%7Cyyy|0|no alternative matches" \
    "status=active%7Cpending,ts>=1785002000|1000|alternatives AND a range window still intersect" \
    "ts=1785000005%7C1785000009|2|alternatives on a RANGE-indexed field are not dropped" \
    "status=active%7C%7Cpending|2000|an empty alternative is skipped, not matched"
  for case in "$@"; do
    W=${case%%|*}; rest=${case#*|}; EXP=${rest%%|*}; DESC=${rest#*|}
    read -r GOT MODE SCANNED <<<"$(cnt "$C" "$(printf '%s' "$W" | sed 's/=/%3D/; s/>=/%3E%3D/')")"
    if [ "$GOT" = "$EXP" ]; then
      check "$layer: $DESC ($EXP, mode=$MODE)" 1
    else
      check "$layer: $DESC — expected $EXP, got $GOT (mode=$MODE)" 0
    fi
  done

  # the point of alternatives over general OR: the union must stay INDEXED. A
  # scan would return the same numbers, so correctness alone cannot detect the
  # regression that matters.
  read -r GOT MODE SCANNED <<<"$(cnt "$C" "status%3Dactive%7Cpending")"
  case "$MODE" in
    *union*|cold-index*) check "$layer: the union is served from the index (mode=$MODE)" 1 ;;
    *) check "$layer: the union fell back to a scan (mode=$MODE)" 0 ;;
  esac
  # ...and it must examine only the union, not the collection
  if [ "$SCANNED" != "-" ] && [ "$SCANNED" -le 2000 ] 2>/dev/null; then
    check "$layer: only the union was examined ($SCANNED of 4000)" 1
  else
    check "$layer: examined $SCANNED docs for a 2000-doc union" 0
  fi

  # find must agree with count, project, and respect limit
  FOUND=$(curl -s -m 40 "$B/find?coll=$C&where=status%3Dactive%7Cdone&limit=5&fields=status" -H "$A")
  echo "$FOUND" | python3 -c '
import json,sys
d = json.load(sys.stdin)["data"]
it = d["items"]
ok = len(it) == 5 and all(set(x["doc"]) == {"status"} for x in it) \
     and all(x["doc"]["status"] in ("active","done") for x in it)
sys.exit(0 if ok else 1)' \
    && check "$layer: find returns only matching docs, projected, within limit" 1 \
    || check "$layer: find disagrees with the clause ($(echo "$FOUND" | head -c 120))" 0

  # alternatives must not leak into the OTHER operators, where `|` is just a byte
  read -r GOT MODE SCANNED <<<"$(cnt "$C" "status~%3Dact%7Cpend")"
  [ "$GOT" = "0" ] && check "$layer: ~= treats | literally (no accidental OR)" 1 \
    || check "$layer: ~= silently gained alternatives (got $GOT)" 0
done

curl -s -m 10 -X POST "$B/shutdown" -H "$A" >/dev/null 2>&1
sleep 0.4; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
rm -rf "$D"

if [ "$fails" -eq 0 ]; then echo '{"ok":true,"in_clause":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
