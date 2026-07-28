#!/usr/bin/env bash
# grange as a LIBRARY, not a server.
#
# grange has two consumers and only one of them speaks HTTP. poche (an
# agent-first CMS) compiles grange's engine modules directly into its own binary
# and calls gr_use/gr_put/q_find in-process — no server, no routes, none of the
# machinery every other harness here drives.
#
# That consumer broke and nobody noticed. Milestones added cross-module calls
# (query -> qcost, cold -> coldindex/coldrange/coldsort) until the subset poche
# links stopped compiling:
#
#     error: [undefined-field] cold_flush: undefined variable "g_cifields"
#
# Nothing in grange's gate compiles a subset, because grange always builds all
# of itself. So this pins the contract: the embeddable core must compile ALONE,
# and must work when driven as a library — including gr_reset(), which is how an
# embedder keeps a long-lived process flat and which grange's own server never
# calls.
set -u
BIN_MACHIN="${MACHIN:-machin}"
SRC="$(cd "$(dirname "$0")/.." && pwd)/src"
FRAMEWORK="${FRAMEWORK:-$(cd "$(dirname "$0")/../../machin/framework" 2>/dev/null && pwd)}"
fails=0
check() { if [ "$2" = "1" ]; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

# The embeddable core: storage + indexes + queries, with no server, no tenancy,
# no CLI. Keep this list in sync with what an embedder actually needs; if a
# module is added here, embedders must add it too, and that is the point of
# having the list in one place.
CORE=(
  "$SRC/engine.src" "$SRC/registry.src"
  "$SRC/cold.src" "$SRC/coldindex.src" "$SRC/coldrange.src" "$SRC/coldsort.src"
  "$SRC/index.src" "$SRC/range.src" "$SRC/qcost.src" "$SRC/query.src" "$SRC/order.src"
)

# a stub main, because machin (correctly) refuses a program with no entry point:
# what is being checked is that the modules RESOLVE each other, not that they
# form a program on their own
STUB=$(mktemp -d /tmp/grange-embedchk-XXXX)
printf 'func main() { ok, e := gr_use("/tmp/x", "c")  println(str(ok) + e) }\n' > "$STUB/main.src"
OUT=$("$BIN_MACHIN" check "${CORE[@]}" "$STUB/main.src" 2>&1 | tail -1)
rm -rf "$STUB"
echo "$OUT" | grep -q "^ok" && check "the embeddable core compiles on its own" 1 \
                            || check "the embeddable core compiles on its own ($OUT)" 0

# ...and works when driven as a library. This is the shape poche uses: open a
# collection, write, query, and periodically gr_reset() to keep RSS flat.
WORK=$(mktemp -d /tmp/grange-embed-XXXX)
mkdir -p "$WORK/db"
cat > "$WORK/embedder.src" <<'EOF'
// A minimal embedder: no server, no HTTP — just the engine, the way poche uses it.
func main() {
    db := env("EMBED_DB")
    ok, errmsg := gr_use(db, "posts")
    if ok == 0 { println("FAIL: gr_use " + errmsg)  return }
    i := 0
    while i < 300 {
        gr_put("p" + str(i), "{\"n\":" + str(i) + ",\"tag\":\"t" + str(i % 5) + "\"}")
        i = i + 1
    }
    if gr_commit() == 0 { println("FAIL: commit")  return }
    if gr_index_add("n", "", "range") == 0 { println("FAIL: index")  return }

    cj := q_count("tag=t1")
    cv, cerr := json_get(cj, ".count")
    println("count=" + cv)

    // ordered + paginated, the query a CMS listing actually needs
    d, ordok, why := q_find_page("", 3, "n", 1, "")
    if ordok == 0 { println("FAIL: ordered query: " + why)  return }
    n0, e0 := json_get(d, ".items[0].doc.n")
    nx, ex := json_get(d, ".next")
    println("newest=" + n0)

    // gr_reset() is how an embedder keeps a long-lived process flat: it commits,
    // drops every in-memory cache, and frees the arena. Data must survive it,
    // and every cached pointer into that arena must have been dropped.
    r := 0
    while r < 5 {
        if gr_reset() == 0 { println("FAIL: gr_reset")  return }
        ok2, err2 := gr_use(db, "posts")
        if ok2 == 0 { println("FAIL: reopen after reset " + err2)  return }
        // compare against a LITERAL, never against a value read before the
        // reset: gr_reset() frees the arena, so anything the CALLER is still
        // holding dangles too, not just grange's internals. The first version
        // of this test compared with a pre-reset string and printed
        // `60 != 0<garbage>`, which is the contract demonstrating itself.
        c2 := q_count("tag=t1")
        v2, e2 := json_get(c2, ".count")
        if v2 != "60" { println("FAIL: count after reset = " + v2)  return }
        // the unfiltered count too: it is cached, and the cache holds the db and
        // collection names the reset just freed
        tj := q_count("")
        tv, terr := json_get(tj, ".count")
        if tv != "300" { println("FAIL: total after reset = " + tv)  return }
        r = r + 1
    }
    // A SECOND collection after a reset. The count cache keys on (db, coll,
    // seq); if the reset left the cached db/coll dangling, this comparison
    // reads freed memory, and a spurious match would answer with the OTHER
    // collection's count.
    ok3, err3 := gr_use(db, "other")
    if ok3 == 0 { println("FAIL: use other " + err3)  return }
    j := 0
    while j < 7 {
        gr_put("o" + str(j), "{\"n\":" + str(j) + ",\"tag\":\"t1\"}")
        j = j + 1
    }
    gr_commit()
    oj := q_count("")
    ov, oerr := json_get(oj, ".count")
    if ov != "7" { println("FAIL: other collection counted " + ov + ", expected 7")  return }
    println("other-collection-count=7")
    println("survived-resets=5")
    println("OK")
}
EOF

# build rather than run: `machin run` rejects this program with "2 variables but
# a single value on the right" while `machin check` accepts it, and a compiled
# binary is what an embedder actually ships anyway.
"$BIN_MACHIN" encode "${CORE[@]}" "$WORK/embedder.src" > "$WORK/e.mfl" 2>/dev/null
"$BIN_MACHIN" build "$WORK/e.mfl" -o "$WORK/emb" >/dev/null 2>&1
RUN=$(EMBED_DB="$WORK/db" "$WORK/emb" 2>&1 | tail -6)
echo "$RUN" | grep -q "^OK" && check "the engine works driven as a library" 1 \
                            || check "the engine works driven as a library ($(echo "$RUN" | tr '\n' ' ' | head -c 140))" 0
echo "$RUN" | grep -q "count=60" && check "queries answer correctly in-process" 1 \
                                  || check "queries answer correctly in-process ($(echo "$RUN" | grep count= | head -1))" 0
echo "$RUN" | grep -q "newest=299" && check "ordered query returns the newest first" 1 \
                                   || check "ordered query returns the newest first ($(echo "$RUN" | grep newest= | head -1))" 0
echo "$RUN" | grep -q "other-collection-count=7" && check "a different collection after reset is not answered from the stale cache" 1 \
                                          || check "a different collection after reset is not answered from the stale cache ($(echo "$RUN" | grep -i 'other' | head -1))" 0
echo "$RUN" | grep -q "survived-resets=5" && check "data and caches survive gr_reset()" 1 \
                                          || check "data and caches survive gr_reset()" 0

rm -rf "$WORK"
if [ "$fails" -eq 0 ]; then echo '{"ok":true,"embed":"pass"}'; exit 0; fi
echo '{"ok":false,"failures":'"$fails"'}'
exit 1
