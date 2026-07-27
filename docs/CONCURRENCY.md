# Concurrency roadmap (grange)

Today `grange serve` is **single-actor by construction**: one accept loop, zero
goroutines touching `g_mem`. That keeps machin's race analysis green and makes
crash/recovery proofs tractable.

## Goal

Unlock concurrent readers (and eventually pipelined writers) without giving up
race-freedom.

## Design (mailbox)

```
accept loop ──► req chan ──► single engine actor ──► resp chan per waiters
                  ▲
 watch parkers ───┘  (still woken by actor after commit)
```

- All `gr_*` / index / WAL mutations stay on one goroutine (the actor).
- HTTP workers only parse requests and wait on reply channels.
- `GRANGE_WORKERS` caps parked clients; the actor stays 1.

## Non-goals (for now)

- Shared-memory readers over `g_mem`
- Multi-process writers on one db dir (use `follow` replicas instead)

Tracked for poche CMS load and hosted grange. Implementation lands when a
dogfood (poche cloud / grange.intrane.fr) measures accept-queue saturation.

---

## M31: the measurement, and what it says about the design above

The plan above said implementation lands "when a dogfood measures accept-queue
saturation". M31 did the measuring, and the result changes the plan.

On a 100k-document cold collection, with one unindexed scan looping:

| | idle server | while one scan runs |
|---|---|---|
| a get by id | 0.2 ms | 85 ms (p90 96 ms) |

A 425x degradation from a SINGLE competing query, and on the hosted instance it
is cross-tenant: one tenant's scan stalls every other tenant. That is an
isolation defect, not a throughput preference.

**The mailbox design above would not have fixed it.** It keeps the actor at 1
and moves only request parsing off it — but the 82 ms is engine work (page
reads and per-document matching), which stays on the actor either way. Building
it first would have added goroutines, channels and a `GRANGE_WORKERS` knob, and
left the measured number where it was. Worth writing down: the design was
drafted from an assumption about where the time goes, and the assumption was
wrong.

### What M31 did instead

Bound the blast radius rather than parallelise it:

- **Accounting, always on.** Every query response now carries `scanned` (docs
  examined) and `pages` (pages read) next to its existing `mode`. On the same
  collection, an indexed lookup reports 2 pages / 0 docs where the scan reports
  256 pages / 50,000 docs — a 128x difference the caller can finally see.
- **A budget, off by default.** `GRANGE_MAX_SCAN_DOCS` / `GRANGE_MAX_SCAN_PAGES`
  abort a query that exceeds them, with an error naming the field to index.
  Self-hosted grange stays unlimited (it is one tenant's own machine); the
  hosted instance sets them.

Measured effect on the innocent caller's tail latency, same workload:

| | p90 of a get while a scan loops |
|---|---|
| no budget | 79 ms |
| `GRANGE_MAX_SCAN_DOCS=2000` | 3 ms |

`scripts/isolation_test.sh` (`make isolation`) asserts that ratio, that the
over-budget scan is refused rather than silently truncated, that the error names
the field, and that declaring the suggested index makes the same query succeed.

### What is still open

A budget refuses expensive queries; it does not make them concurrent. A tenant
with a legitimately large scan is still serialised against everyone else. The
honest options, in the order they are worth trying:

1. **Read replicas over the same directory.** `serve --follow` already works
   against a live primary's directory and is proven by the replication fuzz.
   Routing reads to N followers gives real read concurrency with no engine
   change and no new race surface — an ops recipe, not a feature.
2. Snapshot reads from immutable cold runs, which never change once their
   manifest exists. This is the only path to in-process read concurrency that
   machin's inferred race-freedom would accept without locks.
3. The mailbox, last, and only if parsing ever actually shows up in a
   measurement — which it did not here.
