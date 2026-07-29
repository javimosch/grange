---
name: grange-embed
description: Use grange as a LIBRARY compiled into your own machin binary rather than as a server — the module list that must be linked, the in-process API, and the gr_reset() contract. Use when building a machin app that stores documents (poche does this).
---

# Embedding grange

grange has two consumption modes and only one speaks HTTP. **poche**, an
agent-first CMS, compiles grange's engine into its own binary and calls it
in-process. If you are writing a machin app that needs storage, this is usually
the mode you want: no second process, no port, no token.

## The module list is a contract, not a suggestion

grange's modules call each other, so a subset either resolves or does not
compile at all. Link **all** of these:

```
src/engine.src  src/registry.src
src/cold.src    src/coldindex.src  src/coldrange.src  src/coldsort.src
src/index.src   src/range.src      src/qcost.src      src/query.src
src/order.src
```

Dropping one is not "fewer features" — it is a build error like
`undefined variable "g_cifields"`. poche's build broke exactly this way when
grange added cross-module calls, and stayed broken until someone rebuilt it,
because nothing in grange's own gate compiled a subset. `scripts/embed_test.sh`
(`make embed`) now pins the list; keep your build in sync with it.

Build against a sibling checkout rather than vendoring, so a grange fix reaches
you:

```sh
GRANGE_SRC="${GRANGE_SRC:-$ROOT/../grange/src}"
```

## The in-process API

```
gr_use(db, coll)          -> (ok, errmsg)   open/switch collection
gr_put(id, doc)                             stage a write
gr_del(id)                                  stage a delete
gr_commit()               -> ok             durable (fsynced) on return
gr_index_add(field, sums, kind)             kind "range" for ordering/cursors
q_find(where, limit)      -> json
q_count(where)            -> json
q_find_page(where, limit, order, desc, after) -> (json, ok, why)
gr_verify(deep)           -> (json, issues)
gr_compact()
```

Query semantics are identical to the served ones — see `grange-query`.

## gr_reset(): the contract that will bite you

`gr_reset()` commits pending writes, drops every in-memory cache and frees the
arena. It is how a long-lived embedder keeps RSS flat (poche calls it every N
requests) — grange's own server leaves it off by default.

**It frees the arena, so it invalidates everything the CALLER is still holding,
not just grange's internals.** A string read out of a query before the reset is
garbage after it:

```
count before reset: 60
count after  reset: 0<garbage>     // same variable, freed memory
```

Call it only where nothing is in flight: after the response is written, with no
parked watchers (they hold collection names) and no staged writes.

The same hazard applies to your own globals. Across an arena reset, string
LITERALS, `env()` values and `args()` values survive; **computed strings are
silently corrupted** (machin#540). Re-derive anything else from `args()`/`env()`
directly — not from a parsed flag struct, whose internal maps are themselves
computed. grange re-initialises its own `bytes("\n")` separator inside
`gr_reset()` for this reason: without it every page walk searched for garbage,
pages read as empty, and only the integrity checker noticed.

## Storage mode

A collection is hot (whole dataset in memory) or cold (disk-resident pages).
Embedders default to hot, which is right for CMS-sized data; call the cold
conversion for archival collections. See `grange-operate`.
