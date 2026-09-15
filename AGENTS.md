# AGENTS.md

Orientation for agents working on **grange** — a machin-native document database.

> **Start here: run `./grange guide`.** It emits the version-exact feature
> catalog — every verb, route, `GRANGE_*` variable, flag, and operator — as
> JSON. The guide is generated from the same source as the binary, so it never
> drifts. `make doccoverage` fails if anything is undocumented.

## What this is

grange is a document store written in pure MFL (machin). It pairs with machin
apps the way SQLite pairs with C: embed `src/engine.src` in your binary, or
drive the standalone CLI. One ~7.5 MB static binary, no dependencies.

```
.mfl (canonical text) → parse → infer types → emit C → cc -O2 → native binary
```

## Source layout

| File | What it is |
|------|-----------|
| `src/engine.src` | Core database: open, put, get, del, commit, WAL, recovery |
| `src/tenant.src` | Multi-tenancy, billing, rate limiting, token cache, RBAC |
| `src/serve.src` | HTTP server + main accept loop (single-actor) |
| `src/serverbac.src` | RBAC route + follower spawn + write-route classifier |
| `src/servemeta.src` | Account/collection metadata routes |
| `src/servebulk.src` | `/bulk` endpoint |
| `src/serveread.src` | Data-plane read routes + `/memory` |
| `src/serveproxy.src` | Read proxy to follower replicas |
| `src/servereset.src` | Periodic arena reset (`GRANGE_RESET_EVERY`) |
| `src/cli.src` | Guide + machine-readable help catalog |
| `src/ready.src` | `/ready` checks (disk, RSS, backup age, WAL) |
| `src/watch.src` | `/watch` long-poll + parked socket management |
| `src/daemon.src` | Daemon lifecycle |
| `src/landing.src` | `/` landing page + `/llms.txt` |
| `src/cold.src` | Cold storage (disk-resident collections) |
| `src/index.src` | Index build + query |
| `src/query.src` | Query parsing + execution |
| `src/verify.src` | Integrity check (`grange verify`, `GET /verify`) |

The build is `Makefile` — `machin encode` concatenates the `.src` files into
`grange.mfl`, then `machin build` compiles it.

## The single-actor model

`serve` is one accept loop: `accept → read_request → srv_handle → write`. No
goroutines, no threads, no shared mutable state between requests. Machin's
inferred data-race analysis verifies this on every build.

**Concurrent reads** are process-level: `GRANGE_CONCURRENT_READS=1` auto-spawns
a `--follow` replica on port+1 and proxies GETs to it. Writes stay on the
primary. This is the safe way to add concurrency without touching engine state.

## Auth model

- `Authorization: Bearer <token>` or `?token=<token>`
- Admin token: `--token` or `GRANGE_TOKEN`
- Tenant signup: `POST /tenants` with `X-Peage-Wallet`
- Tenant tokens: `gt_...` (default `rw`), or `POST /tokens` for `ro`/`rw`
- Token roles persist in `_sys` (`tok-<token>` records)

## Key conventions

- **Docs are single-line minified JSON** — no pretty-printing, ever
- **Errors are typed**: `{"ok":false,"error":{"type":"auth",...}}` with semantic exit codes (80–119)
- **Every route is exact-match** — `/count` matches only `/count`, not `/counter`
- **All writes go through `gr_commit()`** — one immutable WAL chunk per commit
- **Arena memory** — MFL allocates on an arena; `gr_reset()` frees it but corrupts
  globals holding arena pointers (ARENA003 warnings are about this)
- **`g_nl` is the only computed global** — `bytes("\n")`, rebuilt after `gr_reset()`

## Testing

```sh
make build    # build the binary
make test     # unit tests (915 assertions)
make verify   # everything: unit, crash, fuzz, bench, doc coverage, soak
```

Individual harnesses: `make rbac promote concurrent_reads memory backup
durability isolation pagination inclause doccoverage telemetry indexbuild
retention replicas concurrent diskfull ratelimit qinject idxcorrupt walpartial
sigterm soak bench crash fuzz`

Test scripts live in `scripts/`. They must:
- Use `set -e` and clean up spawned processes/temp dirs
- Use `ss -tlnp` to find PIDs (not `pkill -f` — it can match the test itself)
- Be deterministic (fixed ports, fixed seeds)

## Gotchas

- **`serve.src` is over 500 LOC** — the engineering target is 500, and it was
  already over before recent work. New logic goes in `serverbac.src` or a new
  file, not `serve.src`.
- **`gr_use` returns 2 values** — `ok, err := gr_use(db, coll)`
- **`exec()` is synchronous** — it waits for the command. Use `nohup ... &` to
  background a process.
- **Cold collections** have their own code path (`cold.src`, `coldindex.src`,
  `coldquery.src`) — the fuzz tests are the source of truth for correctness.
- **The landing page is a string** — `src/landing.src` is one giant string
  concatenation. Edit carefully — a missing `+` or quote breaks the build.

## Files that must stay in sync

- `src/cli.src` — the guide catalog (every route, env var, flag must appear)
- `Makefile` — `verify` must list every test target
- `scripts/routes_test.sh` — probes every HTTP route
- `scripts/doccoverage_test.sh` — checks the guide covers everything

## Deployment

See [`docs/deploying.md`](docs/deploying.md) for generic deployment patterns
(backup, monitoring, failover, read replicas). The hosted instance runs on the
author's infrastructure — specifics are in a private runbook, not this repo.
