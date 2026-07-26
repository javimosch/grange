# Operations notes — hosted instance

## Storage placement: decision & tripwire (2026-07-19)

The hosted instance runs on a small edge VPS (limited RAM + ~1 GB free disk).
Cold mode (`docs are on disk, RAM ~flat`) plus LRU eviction and the RSS
watchdog make that budget workable: ~11 MB disk per 200k cold docs means the
current box holds on the order of 15M documents before disk pressure.

**Considered and rejected:** mounting a remote big-disk box over sshfs as a
cold tier. Smoke-tested first: a single page read was ~112 ms (fine), but a
64-page memtable flush took ~12 s of inline stall (~190 ms per file create over
a ~33 ms RTT link) — unacceptable in the write path. Per-file round-trip costs
kill many-small-files designs on network filesystems.

**Considered and deferred:** a second "archive" instance on the big-disk box.
Works (same binary, flushes take ms on local disk), but two endpoints/tokens
leak infrastructure topology into the user's mental model. Rejected while
there is no customer who needs both cheap terabytes and hot microseconds.

**The plan when pressure arrives:** move the WHOLE instance to the big-disk
box behind the same domain — the reverse proxy flips its backend URL, users
see nothing but ~60–90 ms added latency. Cutover: rsync the data dir, start
the service there, flip the proxy, keep the old process stopped as instant
rollback.

**TRIPWIRE: execute that move when the hosted data directories exceed 500 MB
on the edge VPS** (`du -sb data data.tenants`), or earlier if a tenant's
latency-tolerant dataset alone approaches the free-disk margin. Until then:
single instance, no action.

## Memory behaviour in a long-lived server (measured 2026-07-27)

machin reclaims a goroutine's arena when that goroutine **returns**. grange's
server is a single actor whose accept loop never returns, so every allocation it
makes — page reads, parsed lines, built responses — stays resident until the
process exits. This is not a leak in the C sense (nothing is unreachable-but-
tracked); it is arena semantics meeting an infinite loop.

Measured on 50k docs in one process (`stats` reports `rss_kb`, so the numbers are
self-reported, not guessed from a PID):

| phase | RSS after |
|---|---|
| 50k hot writes (the working set itself) | 68 MB |
| convert to cold + flush to pages | +4 MB |
| build a cold index over 50k docs | +49 MB |
| 200 cold point gets | +11 MB (~55 kB/get) |
| 10 indexed counts | +94 MB (~9 MB/query) |
| 5 scanning counts | +16 MB (~3 MB/scan) |

Two corrections to earlier notes: the "flat 4.4 MB at 200k docs" figure was a
**fresh process** (open + count), which is genuinely small but says nothing about
a server under load; and a `pgrep -f "grange serve …"` in an earlier harness
matched the measuring shell instead of the server, which produced both absurdly
large and absurdly small readings. Always read `stats.rss_kb`.

Mitigations in place:
- Every path where nothing escapes is wrapped in `arena { }` (flush, index
  build, count scans, indexed counts) — verified by machin's ARENA001 escape
  analysis, which refuses the wrap if a value would outlive the block. This
  roughly halved growth on those paths.
- The RSS watchdog checks every 10 s and, above `GRANGE_MAX_RSS_MB` (100 on the
  hosted primary), commits, flushes throttle counters and exits; systemd
  restarts in ~2 s. Recovery is a WAL replay for hot collections and a manifest
  read for cold ones, so a restart costs milliseconds and loses nothing.
- Parked `/watch` clients are dropped by a restart and must reconnect (the SDKs
  poll again with their last `seq`, which is the normal long-poll cycle).

Next engine milestone: per-request arena scoping. Either handle each request in
a short-lived goroutine (machweb's own `serve` does this — but it trades the
single-actor race-freedom property) or extend ARENA001 to prove escapes
interprocedurally so the whole read path can be wrapped. Until then the
watchdog is the guard, and a request-heavy instance should be sized with the
restart in mind.
