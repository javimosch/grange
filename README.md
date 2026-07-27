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

The server is **multi-collection** (`?coll=` / body `"coll"`, `GET /collections`
lists them) and **single-actor by construction**: a sequential accept loop with
zero goroutines, so there is nothing to race on — and machin's inferred
data-race analysis (`machin check`, no annotations) verifies that on every
build. Collection switching is O(1): MFL maps are reference types, so parking
and restoring a collection's whole state is a handful of map assignments.
Concurrent-reader serving is deliberately future work.

## Hosted: grange.intrane.fr

A managed instance runs at **https://grange.intrane.fr**, with a read replica
at **https://read.grange.intrane.fr** (same tokens, GET routes; writes 403 and
belong on the primary). Signup is self-serve
and agent-first — a [peage](https://peage.intrane.fr) wallet is the only
credential:

```sh
curl -X POST https://grange.intrane.fr/tenants -H "X-Peage-Wallet: pw_..." -d '{"name":"my agent"}'
# -> {"tenant":"t...","token":"gt_...", "pricing":{...}}
```

Your `gt_` token scopes every route to an isolated namespace with **multiple
databases** (`?db=`, default `default`), each holding collections, indexes and
its own WAL. Client SDKs for **Python (`pip i grange-db`), Node.js (`npm i grange-db`), Go, and machin**
live in [`sdk/`](sdk/), with bulk writes (`putMany` — newline-delimited ops,
one commit, all-or-nothing, ~263k docs/s measured over HTTP). **Pricing: pay-as-you-go
storage, €0.15/GB/month above 50 MB free**, accrued continuously and charged
to your wallet via peage (min charge 5 cents; `GET /usage` shows bytes,
accrual, and charges at any time). No subscription, no card on file — fund the
wallet once, the meter does the rest.

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

## Cold storage (disk-resident collections)

`grange cold --db d --coll archive` (or `POST /cold`) converts a collection to
disk-resident: hash-partitioned page files (the same checksummed write-once
format), a bounded memtable, and streaming scans. Measured at 200k docs: **4.4 MB
RSS vs 89.9 MB hot** in a fresh process, point gets read exactly one page file
per run (3 ms cold-start included), scans and compaction stream one page group
at a time. **Cold collections take secondary indexes too** (`grange index --coll archive
--field email`): the index is written as value-partitioned page files, so an
equality lookup reads ONE index page plus only the data pages holding its
candidates. Measured at 100k cold docs: a selective lookup goes **112 ms → 7 ms
(15×)**, a 2000-hit lookup 108 ms → 66 ms, and building an index over 100k docs
takes ~0.9 s per field. Candidates are always re-verified against the
authoritative doc, so a stale index entry (overwritten, moved or deleted doc)
can never leak into results.

Bulk ingest into a cold collection writes each large batch as **its own run**,
straight to pages, so loading never stages the data through memory: a 100k-doc
load peaks at **65 MB** (was 172 MB) and stays under the hosted budget.
`GRANGE_BULK_DIRECT` sets the batch size that takes this path (default 500; 1
forces it, which the fuzzes use).

Cold collections also take **ordered (range) indexes** —
`grange index --coll events --field ts --range` — which store the field's values
sorted across pages with a min/max boundary file per run, so a range query reads
only the pages whose interval overlaps it (`mode:"cold-range"`). Ordered by a
real workload: mirroring a live analytics database showed every dashboard
question is a time range, and those were full scans.

Trade-offs, enforced: no TTL docs on cold collections, `~=` clauses still scan, `stats` reports `docs_estimate`
(an exact cold count streams every page), and gets go from ~µs to ~100 µs.
Hot stays the default — cold is for data bigger than your RAM budget.

## Read replicas

The immutable WAL doubles as a replication log, so replicas need no new
machinery — and no shared memory, so the race-freedom proof stands:

```sh
grange serve --db ./data --follow --port 4445   # local read-only follower: refreshes from the db dir before every read
grange follow --from https://grange.intrane.fr --rtoken gt_... --db ./replica   # LIVE local replica of a hosted db over the /watch feed
```

Cold collections replicate too: a flush replaces WAL chunks with a run (and
restarts chunk numbering), so a follower detects any change to the run set or
generation and reopens rather than replaying chunks it can no longer interpret.
Before this it went **silently stale** — the failure mode a database must never
have — which is why the differential and crash suites below now cover cold.

`follow` resyncs via `/export?format=lines` when behind, then applies watch
deltas (puts + deletes), committing them to its own local WAL. `make crash`-grade
durability applies to the replica too, because it IS a grange db.

## A real workload

`apps/vigie-sync` mirrors a live [vigie](https://vigie.intrane.fr) analytics
database into grange — deliberately a **sidecar** that reads vigie's SQLite
read-only, so a live product carries none of the risk of the experiment, and
SQLite stays the source of truth and therefore the **oracle**:

```sh
vigie-sync sync    --sqlite /opt/vigie/vigie.db --token gt_...   # replay new rows
vigie-sync compare --sqlite /opt/vigie/vigie.db --token gt_...   # every aggregate must match
```

`compare` checks totals, per-site and per-kind counts and a 24-hour window
against SQLite: **14/14 match** on the live data. On dk1 it runs continuously —
a systemd timer syncs every 10 minutes and a daily one re-checks against the
oracle, so the mirror is a standing proof rather than a one-off demo. Dashboard-shaped queries on the
mirror, measured on the host (604 events, cold, indexed): the 24-hour window —
the query that was a full scan before the range index — answers in **3 ms**. The workload is what asked for cold
range indexes — see above.

## How cold storage is verified

Cold mode is the youngest and most intricate code in the engine (cross-run
shadowing, tombstones, compaction, index staleness), so it is tested against
the simplest thing that cannot be wrong:

- **Differential fuzz** (`make fuzz`) — the same pseudo-random op stream (puts,
  overwrites, deletes, flushes, compactions, mid-stream index declarations) is
  applied to a **hot collection as oracle** and a cold collection, comparing the
  *entire visible state* plus counts, finds and aggregates after **every** op.
  12,000 ops across 10 seeds, zero divergence.
- **Mutation-tested harness** — the fuzzer itself was validated by injecting
  four deliberate bugs (ignore run tombstones, skip the memtable in index
  lookups, drop memtable docs during compaction, skip candidate verification).
  The first version caught only three; the state comparison was strengthened
  until all four fail loudly. A test that never fails proves nothing.
- **Replication differential fuzz** (`make fuzz`) — a real primary and a
  `--follow` server over the same directory, plus the remote `grange follow`
  path, driven by a random op stream that includes the transitions which broke
  replication before (cold conversion, flushes that delete the chunks a follower
  was tracking, compaction, index builds) and a **follower restart mid-stream**.
  The follower's full state must equal the primary's after every op. It found
  two real bugs on its first run (see below) and is mutation-tested too.
- **Integrity check** (`grange verify` / `GET /verify`) — walks every file's
  checksum and record stream, cross-checks each cold manifest against the pages
  it claims, and confirms declared indexes exist and agree with the data.
  Detects a flipped byte, a truncated page and a missing index page; exit 92 on
  damage. Both crash harnesses call it after every recovery, so a kill -9 has to
  leave the database *structurally* intact, not merely answerable.
- **Crash injection** (`make crash`) — `kill -9` mid-flight on cold collections,
  where a commit spans many files (pages, then a manifest) and compaction
  rewrites a whole generation. Recovery must open cleanly, agree with filtered
  queries, accept writes, and survive a compaction of the recovered state.

## Build & verify

```sh
make build    # needs machin >= 0.108
make verify   # check + tests (69) + 100k bench + crash harness
```

## Scope & honesty (M5)

- A long-lived server's RSS grows with the work it has done (see
  [docs/OPERATIONS.md](docs/OPERATIONS.md)): machin reclaims a goroutine's arena
  when it returns, and the single-actor loop never returns, so page reads and
  response building accumulate. Hot paths that can be arena-scoped are, and the
  RSS watchdog (`GRANGE_MAX_RSS_MB`) restarts the process before it hurts —
  crash-safety makes that a non-event. Per-request arena scoping is the next
  engine milestone.
- Hot collections keep the whole dataset + indexes in memory (memtable = the db); segments make cold open fast, not memory small. Steady-state RSS at 100k docs + 1 index is ~120 MB (fresh process); the bench process peaks at ~440 MB from MFL arena temporaries — a memory diet is the standing target.
- `--where` supports equality + numeric ranges. Equality clauses use buckets; a single range clause on a `--range` field uses the sorted projection (built lazily on the first range query after a write — the build cost is the first query's, honestly). Multi-clause range queries scan. Aggregate registers cover count/sum/avg; `--minmax` computes min/max on the scan path.
- Durability is process-crash-exact (proven by `make crash`), OS-crash best-effort (no fsync builtin in MFL yet).
- `grange serve` handles one request at a time (correctness first) across any number of collections and tenants. Metering charges storage only (no per-query fees yet); billing sweeps piggyback on requests every 6h. Concurrent readers are next.

MIT.
