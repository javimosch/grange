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

### Update (same day): fixed upstream in machin

The next milestone turned out to be two compiler changes rather than a grange
restructure (machin PR #534):

- **`escape(v)`** carries exactly one value out of an `arena { }` block (copied
  into the enclosing arena before the block is reclaimed), so a handler can do
  heavy transient work and return one answer. ARENA001 still refuses every
  *other* escape, so the proof keeps its teeth.
- **Scoped maps** are now allocated from the current arena. Maps were
  malloc-only with no free path anywhere, so every transient map — a per-page
  group, a per-request lookup table — leaked permanently and defeated arena
  blocks entirely for map-using code. Long-lived maps (main arena) keep
  malloc + per-entry free, so delete-heavy caches are unaffected.

grange's read routes now run inside `arena { … escape(body) }`, with `q_warm()`
performing anything state-mutating (TTL sweep, dirty range-projection rebuild)
*before* the block so nothing allocated inside is retained. Measured again at
100k cold docs, same sequence as the table above:

| phase | RSS after |
|---|---|
| 100k cold load | 221 MB |
| build a cold index | 613 MB |
| 20 indexed counts | 669 MB |
| 10 scanning counts | **669 MB (+0)** |
| 5 × find(2000 docs) | 673 MB (+4) |
| 50 point gets | **673 MB (+0)** |

(M24 update: bulk ingest into a cold collection now writes each large batch
directly to its own run instead of staging it through the memtable, so a 100k
load peaks at 65 MB rather than 172 MB — under the hosted 100 MB budget, no
watchdog restart. What remains per request is the request body itself, which
would need the whole HTTP read path scoped.)

Query serving is now flat — RSS settles at the working-set peak instead of
climbing per request. What still grows is the write/build path (bulk load and
index build), which retains data by nature; the watchdog remains the guard for
those, and an index build over a very large collection can still trip it (a
restart mid-build is safe: without its manifest an incomplete run is ignored,
the declaration persists, and queries fall back to scanning until a later
compaction rebuilds it).

## Integrity checks (M23)

`grange verify --db <dir> --coll <name>` (or `GET /verify?coll=…`) reports
`{intact, mode, gen, files_checked, runs, issues[]}` and exits 92 if anything is
wrong. It is the answer to "is my data actually intact?", which queries cannot
give: a query only touches the pages it needs.

Use it:
- after any crash or watchdog restart (both crash harnesses now do);
- before and after moving a database between machines — when the 500 MB tripwire
  fires, verify on both sides is the difference between a migration and a hope;
- from a cron on the hosted instance if you want early warning of disk rot.

It checks checksums and record structure for every `.grg`/`.cmeta` file, that a
cold manifest's count matches what its pages actually hold, that every field a
run says it indexed has its index pages, and (deep mode) that a sample of index
entries names ids the run really holds with the value the entry claims.
