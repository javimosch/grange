<p align="center">
  <img src="assets/logo/grange.svg" width="96" height="96" alt="grange">
</p>

<h1 align="center">grange</h1>

<p align="center">
  <strong>A machin-native document database — agent-first, single binary, crash-safe by construction.</strong>
</p>

<p align="center">
  <a href="https://github.com/javimosch/grange/actions/workflows/ci.yml"><img src="https://github.com/javimosch/grange/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/javimosch/grange/releases"><img src="https://img.shields.io/github/v/release/javimosch/grange" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License"></a>
  <a href="https://grange.intrane.fr/llms.txt"><img src="https://img.shields.io/badge/API-agent--first-brightgreen" alt="Agent-first API"></a>
</p>

<p align="center">
  <em>French for "barn" — a place where documents live.</em>
</p>

---

## Quick start

```sh
# Self-hosted — one binary, no install
curl -sSL -o grange https://github.com/javimosch/grange/releases/latest/download/grange-linux-x86_64
chmod +x grange
./grange put   --db ./data --coll notes --doc '{"title":"first","votes":3}'
./grange index --db ./data --coll notes --field votes --range
./grange find  --db ./data --coll notes --order votes --desc --limit 5

# Or hosted — skip the install, signup is one curl
curl -s https://grange.intrane.fr/llms.txt   # the full API contract, written for agents
```

## What it is

A document store written in pure [MFL](https://github.com/javimosch/machin) that pairs with machin apps the way SQLite pairs with C. Embed the engine (`src/engine.src`) or drive the standalone CLI. No server, no dependencies, no cgo — one ~7.5 MB static binary.

**Agent-first**: JSON-only stdout, typed errors on stderr, semantic exit codes (80–119), `guide` + `help-json` introspection. No human UI, ever.

**Crash-safe**: every commit is one immutable, checksummed WAL chunk. `kill -9` leaves exactly the committed prefix — proven by `make crash`.

**Faster than SQLite on indexed workloads** (100k docs, `make bench`):

| metric | grange | SQLite |
|---|---|---|
| bulk insert, 2 indexes | **278k docs/s** | 25k rows/s |
| point get (avg of 1000) | **5 µs** | 17 µs |
| indexed count × 1000 | **<1 ms** | 1,937 ms |
| group-by count/sum/avg × 1000 | **<1 ms** | 49,114 ms |
| range count × 1000 | **<1 ms** | 257 ms |

## Features

- **Multi-collection**: `?coll=` on every route, `GET /collections` lists them
- **Cold storage**: `POST /cold` converts a collection to disk-resident (4.4 MB RSS at 200k docs vs 89.9 MB hot)
- **Indexes**: equality (`--sums` for O(1) agg) and range (`--range` for > < >= <=)
- **RBAC**: `POST /tokens` issues `ro`/`rw` tokens per tenant
- **Read replicas**: `--follow` on a second port, or `GRANGE_CONCURRENT_READS=1` to auto-spawn
- **Failover**: `POST /promote` flips a follower to primary in one request
- **Memory**: `GRANGE_MAX_RSS_MB` watchdog + `GRANGE_RESET_EVERY` arena reclaim + `GET /memory` introspection
- **Backup**: `scripts/backup.sh` copies, verifies checksums, prunes

## Server

```sh
grange serve --db ./data --port 8801 --token secret
```

```sh
curl -X POST :8801/put -H "Authorization: Bearer $T" -d '{"doc":{"status":"active","score":9}}'
curl ":8801/find?where=score>=5" -H "Authorization: Bearer $T"
```

## Hosted

<https://grange.intrane.fr> — pay-as-you-go, €0.15/GB/month above 50 MB free. Signup is one curl with a [peage](https://peage.intrane.fr) wallet.

## Docs

- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — production readiness, gaps, the honest verdict
- [`docs/CONCURRENCY.md`](docs/CONCURRENCY.md) — the single-actor model and how to bound it
- [`docs/deploying.md`](docs/deploying.md) — deployment patterns (backup, monitoring, failover)
- [`grange guide`](https://github.com/javimosch/grange) — the machine-readable feature catalog

## Build

```sh
make build    # needs machin >= 0.108
make verify   # 32 harnesses: unit, crash, fuzz, bench, doc coverage
```

## License

MIT
