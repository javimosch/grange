---
title: Building an agent-first document database in 75KB
published: false
description: How grange turns a stack-based language into a crash-safe document DB with O(1) aggregates, cold storage, and a billing model your AI agent can settle itself.
tags: database, agents, selfhosted, golang
cover_image: 
---

# Building an agent-first document database in 75KB

Most databases are built for humans. They have consoles, dashboards, connection pools, GUI clients. They expect you to know what a tablespace is. They bill you through a web form with a credit card.

Agents don't need any of that. An agent needs JSON in, JSON out, and a bill it can settle itself.

This is the story of [grange](https://github.com/javimosch/grange) — a document database written in [machin](https://github.com/javimosch/machin), a stack-based language that compiles to a single static binary. It has crash-safe WAL, indexes with O(1) aggregate registers, cold storage for datasets bigger than your RAM, and a hosted instance where signup is one curl with a prepaid wallet. No card on file, no subscription, no console.

## The problem

I build AI agents. Agents produce structured data — leads, transcripts, tool outputs, search results — and they need somewhere to put it. The options are:

- **SQLite**: excellent, but it's a relational database. Agents think in JSON, not in `CREATE TABLE` migrations.
- **Postgres/Mongo**: production-grade, but they need a server, a connection string, a password, and a human to provision them.
- **Firebase/Supabase**: hosted and easy, but they expect a human with a credit card and a dashboard.

What I wanted was a database that an agent could provision itself, query with plain JSON, and pay for per-call — and that I could also self-host as a single binary when the hosted rail didn't fit.

## The language: machin (MFL)

grange is written in [machin](https://github.com/javimosch/machin) (MFL — Machin Forth-like Language), a stack-based language that compiles to native code via a C backend. The choice was deliberate:

- **Single binary**: machin compiles to one static binary (musl, ~7.5 MB). No runtime, no cgo, no glibc floor. It runs on Alpine and `FROM scratch`.
- **Zero goroutines**: the server is a single actor — a sequential accept loop. There is nothing to race on, and machin's inferred data-race analysis verifies that on every build with no annotations.
- **Maps are reference types**: parking and restoring a collection's whole state is a handful of map assignments, so collection switching is O(1).

The trade-off is honest: a single-actor server means one slow query blocks everyone. That's the concurrency ceiling, and it's documented in `docs/CONCURRENCY.md`. For agent workloads — short, indexed, bursty — it's fine. For a thousand concurrent human users running ad-hoc analytics, it's not.

## Crash-safe by construction

Every commit is one immutable, checksummed WAL chunk. The on-disk layout is:

```
<db>/<coll>/seg-<gen>.grg       immutable compacted snapshot
<db>/<coll>/wal-<gen>-<n>.grg   immutable WAL chunk, one per commit
```

Every `.grg` file ends with a `#|<nrecs>|<sha256:12>` trailer. MFL has no file append or rename, so grange never mutates a file: a commit writes a fresh chunk, compaction writes a fresh segment (verified by re-read before anything is deleted).

Recovery is simple: load the newest valid segment, replay its valid chunks in order, drop anything torn. `kill -9` at any moment leaves exactly the committed prefix.

This is proven, not claimed. `make crash` runs 5 rounds of mid-flight SIGKILL, and recovered counts must be exact commit-batch multiples. The repo ships the harness.

## O(1) aggregates: the trick that makes group-by free

This is the feature I'm most proud of. When you declare an index, you can also declare aggregate registers:

```sh
grange index --db ./data --coll leads --field status --sums score
```

This maintains per-group `count`, `sum`, and `avg` incrementally at write time. A group-by query is a map lookup:

```sh
grange agg --db ./data --group-by status --sum score
```

The result: **group-by count/sum/avg × 1000 takes <1 ms**. Not because the query is fast — because the query doesn't scan. The answer was computed at write time and stored in the index.

SQLite, doing the same group-by × 1000, takes 49 seconds.

| workload | grange | SQLite |
|---|---|---|
| bulk insert, 2 indexes maintained | **278k docs/s** | 25k rows/s |
| point get (avg of 1000) | **5 µs** | 17 µs |
| indexed count × 1000 | **<1 ms** (O(1) register) | 1,937 ms |
| group-by count/sum/avg × 1000 | **<1 ms** (O(1) registers) | 49,114 ms |
| range count × 1000 | **<1 ms** (after one-time 79 ms sort) | 257 ms (indexed) |
| full scan, no index (worst case) | 61 ms | 8 ms |

The one row SQLite wins is the unindexed scan — typed columns beat per-doc JSON extraction. The answer is `grange index`: one command, and that query class becomes O(1) or O(bucket) forever.

## Cold storage: 200k docs in 4.4 MB of RAM

Hot collections hold everything in memory. That's fast but doesn't scale beyond your RAM. Cold collections are disk-resident:

```sh
grange cold --db ./data --coll archive
```

Cold mode uses hash-partitioned page files (the same checksummed write-once format), a bounded memtable, and streaming scans. Measured at 200k docs: **4.4 MB RSS vs 89.9 MB hot** in a fresh process.

Cold collections take secondary indexes too. The index is written as value-partitioned page files, so an equality lookup reads ONE index page plus only the data pages holding its candidates. A selective lookup on 100k cold docs goes from 112 ms to 7 ms (15×).

Cold collections also take ordered (range) indexes — `grange index --coll events --field ts --range` — which store values sorted across pages with min/max boundary files. A range query reads only the pages whose interval overlaps it. This came from a real workload: mirroring a live analytics database showed every dashboard question is a time range, and those were full scans.

## The hosted model: your agent pays its own bill

The hosted instance at [grange.intrane.fr](https://grange.intrane.fr) has a signup flow designed for agents, not humans:

```sh
# Get an isolated, metered namespace — the wallet IS the signup
curl -s -X POST https://grange.intrane.fr/tenants \
  -H 'X-Peage-Wallet: pw_...' \
  -d '{"name":"my agent"}'
# -> {"tenant":"t...","token":"gt_...", "pricing":{...}}

# Put a document
curl -s -X POST https://grange.intrane.fr/put \
  -H 'Authorization: Bearer gt_...' \
  -d '{"coll":"leads","doc":{"co":"acme","score":9}}'

# Query it
curl -s 'https://grange.intrane.fr/agg?coll=leads&group-by=co&sum=score' \
  -H 'Authorization: Bearer gt_...'
```

Each tenant gets a separate database directory on disk — separate WAL, separate collections, separate indexes. The token is the only scope key. Storage is metered at €0.15/GB/month, first 50 MB free, accrued continuously and charged to the wallet via [peage](https://peage.intrane.fr). No subscription, no card on file.

The agent contract is published at [grange.intrane.fr/llms.txt](https://grange.intrane.fr/llms.txt) — the full API surface, written for machines, not for browsers.

## Dogfooding: this page runs on grange

The landing page's own subscribe form is a paying tenant of the hosted instance. The flow:

1. User enters email on the landing form
2. Form POSTs to `subscribe.grange.intrane.fr/subscribe` (a 130-line machin app)
3. The subscribe service uses the machin client SDK to PUT the email into hosted grange
4. Every subscriber email is a document in the `subscribers` collection

The count is live and public:

```sh
curl -s https://subscribe.grange.intrane.fr/count
# -> {"ok":true,"data":{"subscribers":4}}
```

This is not a demo. It's a real workload — small, but real. The subscribe service is a separate process (a grange actor calling its own HTTP API would deadlock), which is also the honest shape of a customer.

## How it's verified

The repo ships 21 test harnesses and 388 unit assertions. The interesting ones:

- **Differential fuzz** (`make fuzz`): the same pseudo-random op stream is applied to a hot collection (oracle) and a cold collection, comparing entire visible state after every op. 12,000 ops across 10 seeds, zero divergence.
- **Mutation-tested harness**: the fuzzer was validated by injecting four deliberate bugs. The first version caught only three; the state comparison was strengthened until all four fail loudly. A test that never fails proves nothing.
- **Crash injection** (`make crash`): `kill -9` mid-flight on cold collections, where a commit spans many files. Recovery must open cleanly, agree with filtered queries, accept writes, and survive a compaction of the recovered state.
- **Integrity check** (`grange verify`): walks every file's checksum and record stream, cross-checks cold manifests against pages, confirms indexes agree with data. Detects a flipped byte, a truncated page, a missing index page.

## The honest trade-offs

- **Single-actor server**: one slow query blocks everyone. Fine for agent workloads, not fine for concurrent human analytics. Concurrent readers are future work.
- **Unindexed scans are slower than SQLite**: typed columns beat per-doc JSON extraction. The answer is indexes — but you have to declare them.
- **Nobody but the author has run it**: the repo has 0 GitHub stars. The operations verdict in `docs/OPERATIONS.md` says it's suitable for a service whose failure you can tolerate.
- **Linux x86-64 only**: a database server needs POSIX, and machin cross-compiles to wasm and Windows, but those targets aren't useful for a server.

## Try it

```sh
# Self-hosted
curl -sSL -o grange https://github.com/javimosch/grange/releases/latest/download/grange-linux-x86_64
chmod +x grange
./grange guide          # the version-exact feature catalog

# Or hosted — skip the install
curl -s https://grange.intrane.fr/llms.txt   # the full contract, written for agents
```

SDKs: [Python](https://pypi.org/project/grange-db/), [Node.js](https://www.npmjs.com/package/grange-db), Go, machin. All MIT.

---

grange is an [intrane.fr](https://intrane.fr) experiment. Source on [GitHub](https://github.com/javimosch/grange). Hosted at [grange.intrane.fr](https://grange.intrane.fr). Storage billed via [peage](https://peage.intrane.fr).
