# grange

**A machin-native document database — agent-first, single binary, crash-safe by construction.**

grange is a document store written in pure [MFL](https://github.com/javimosch/machin) that pairs with machin apps the way SQLite pairs with C: embed the engine (`src/engine.src`) directly in your binary, or drive the standalone CLI. No server, no dependencies, no cgo — one ~75 KB static binary.

- **Agent-first**: JSON-only stdout, typed errors on stderr, semantic exit codes (80–119), `guide` + `help-json` introspection, per [cli-specs](https://cli-specs.intrane.fr/). No human UI, ever.
- **Crash-safe**: every commit is one immutable, checksummed WAL chunk. `kill -9` at any moment leaves exactly the committed prefix — proven by `make crash` (5 rounds of mid-flight SIGKILL, recovered counts are exact commit-batch multiples).
- **Faster than SQLite on every indexed workload** (100k docs, `make bench`, both engines indexed on the same field, same box):

| metric | grange | SQLite |
|---|---|---|
| bulk insert, 2 indexes maintained | **278k docs/s** | 25k rows/s |
| point get (avg of 1000) | **5 µs** | 17 µs |
| indexed count × 1000 | **<1 ms** (O(1) register) | 1,937 ms |
| indexed find + fetch 33k docs | **5 ms** | 111 ms |
| group-by count/sum/avg × 1000 | **<1 ms** (O(1) registers) | 49,114 ms |
| range count (`score>=900`) × 1000 | **<1 ms** (after a one-time 79 ms sort) | 257 ms (indexed) |
| full scan, no index (worst case) | 61 ms | 8 ms |
| cold open, 100k + index rebuild | 309 ms | — |

The one row SQLite wins is the unindexed scan (typed columns beat per-doc JSON extraction); the answer is `grange index` — one command, and that query class becomes O(1)/O(bucket) forever. Aggregate registers (declare `--sums` on an index) keep per-group count/sum/avg maintained incrementally at write time — a group-by answer costs a map lookup, which is why the agg row is not a typo.

## Model

A database is a directory; a collection is a subdirectory. Docs are minified JSON keyed by id, held in memory, persisted as:

```
<db>/<coll>/seg-<gen>.grg       immutable compacted snapshot (generation gen)
<db>/<coll>/wal-<gen>-<n>.grg   immutable WAL chunk, one per commit
```

Every `.grg` file ends with a `#|<nrecs>|<sha256:12>` trailer. MFL has no file append or rename, so grange never mutates a file: a commit writes a fresh chunk, compaction writes a fresh segment (verified by re-read before anything is deleted). Recovery = load the newest valid segment, replay its valid chunks in order, drop anything torn.

## Use

```sh
grange put  --db ./data --doc '{"name":"ada","status":"active"}'   # -> {"ok":true,"data":{"id":"..."}}
grange get  --db ./data --id <id>
grange find --db ./data --where status=active --limit 50
grange del  --db ./data --id <id>
grange count --db ./data --where status=active
grange index --db ./data --field status --sums score   # declare once: find/count O(bucket|1), agg O(1)
grange index --db ./data --field score --range         # sorted projection: > < >= <= in O(log n)
grange agg --db ./data --group-by status --sum score   # per-group count/sum/avg (--minmax f for min/max)
grange compact --db ./data        # fold WAL chunks into a fresh segment
grange stats --db ./data
grange guide                      # the machine-readable manual
```

`--where` clauses AND together and support `=` plus numeric `>` `<` `>=` `<=`:
`--where "status=active,score>=100"`.

Or run it as a server (`grange serve --db ./data --port 4444`) — same operations
over HTTP/JSON with bearer-token auth (`--token` / `GRANGE_TOKEN`, else one is
generated and printed at startup):

```sh
curl -X POST :4444/put -H "Authorization: Bearer $T" -d '{"doc":{"status":"active","score":9}}'
curl ":4444/find?where=score>=5" -H "Authorization: Bearer $T"    # /get /del /count /agg /index /stats /compact /health
```

The server is **single-actor by construction**: a sequential accept loop with
zero goroutines, so there is nothing to race on — and machin's inferred
data-race analysis (`machin check`, no annotations) verifies that on every
build. Concurrent-reader serving is deliberately future work.

Embedded, from any machin app:

```sh
machin encode framework/flags.src src/engine.src yourapp.src > app.mfl && machin build app.mfl -o app
```

```go
ok, err := gr_open("./data", "users")
gr_put("u1", "{\"name\":\"ada\"}")
gr_commit()                        // durable: one WAL chunk
doc, found := gr_get("u1")
```

## Build & verify

```sh
make build    # needs machin >= 0.108
make verify   # check + tests (58) + 100k bench + crash harness
```

## Scope & honesty (M3)

- Whole dataset + indexes live in memory (memtable = the db); segments make cold open fast, not memory small. Steady-state RSS at 100k docs + 1 index is ~120 MB (fresh process); the bench process peaks at ~440 MB from MFL arena temporaries — a memory diet is the standing target.
- `--where` supports equality + numeric ranges. Equality clauses use buckets; a single range clause on a `--range` field uses the sorted projection (built lazily on the first range query after a write — the build cost is the first query's, honestly). Multi-clause range queries scan. Aggregate registers cover count/sum/avg; `--minmax` computes min/max on the scan path.
- Durability is process-crash-exact (proven by `make crash`), OS-crash best-effort (no fsync builtin in MFL yet).
- `grange serve` handles one request at a time (correctness first); one server per collection. Concurrent readers, multi-collection serving, and range indexes are next.

MIT.
