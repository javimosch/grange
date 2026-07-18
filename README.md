# grange

**A machin-native document database — agent-first, single binary, crash-safe by construction.**

grange is a document store written in pure [MFL](https://github.com/javimosch/machin) that pairs with machin apps the way SQLite pairs with C: embed the engine (`src/engine.src`) directly in your binary, or drive the standalone CLI. No server, no dependencies, no cgo — one ~75 KB static binary.

- **Agent-first**: JSON-only stdout, typed errors on stderr, semantic exit codes (80–119), `guide` + `help-json` introspection, per [cli-specs](https://cli-specs.intrane.fr/). No human UI, ever.
- **Crash-safe**: every commit is one immutable, checksummed WAL chunk. `kill -9` at any moment leaves exactly the committed prefix — proven by `make crash` (5 rounds of mid-flight SIGKILL, recovered counts are exact commit-batch multiples).
- **Fast enough to matter** (100k docs, `make bench`, vs the SQLite builtin on the same box):

| metric | grange | SQLite |
|---|---|---|
| bulk insert (batched commits) | **377k docs/s** | 50k rows/s |
| point get (avg of 1000) | **3 µs** | 14 µs |
| filtered scan, 100k docs | 67 ms | 5 ms (indexed) |
| cold open, 100k on disk | 99 ms | — |
| RSS after the run | 305 MB | — |

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
grange compact --db ./data        # fold WAL chunks into a fresh segment
grange stats --db ./data
grange guide                      # the machine-readable manual
```

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
make verify   # check + tests (21) + 100k bench + crash harness
```

## M0 scope & honesty

- Whole dataset lives in memory (memtable = the db); segments make cold open fast, not memory small. Memory overhead is currently ~3 KB/doc (MFL arena allocation) — an M1 target, honestly reported above.
- `--where` is top-level equality only; durability is process-crash-exact, OS-crash best-effort (no fsync builtin in MFL yet).
- Single process, single writer. The concurrent server (`grange serve`), secondary indexes, `agg`, and range queries are next.

MIT.
