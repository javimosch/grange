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
