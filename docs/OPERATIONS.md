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

## The vigie mirror (M25/M26)

A read-only sidecar mirrors the live vigie analytics database into grange:

- `vigie-sync.timer` — every 10 minutes, replays new SQLite rows into the
  hosted tenant's cold `events` collection (cursor kept in grange itself).
- `vigie-compare.timer` — daily, re-checks totals, per-site/per-kind counts and
  a 24-hour window against SQLite, which stays the source of truth.

If `compare` ever reports `match:false`, the mirror is wrong and grange is the
suspect — read the `mismatches` array, then `grange verify` the collection. The
sidecar never writes to vigie and never sits on its request path, so the live
product cannot be harmed by this experiment.

## Ingest memory scales with BATCH SIZE (M27 measurement)

A bulk batch retains memory in the actor's arena roughly in proportion to the
square of its size, not linearly with the documents in it:

| batch size | retained per batch | per doc |
|---|---|---|
| 10k lines | ~6.5 MB | 0.65 kB |
| 25k lines | ~35 MB | 1.4 kB |

So 200k docs loaded in 25k-line batches leaves ~280 MB resident, which on the
hosted 100 MB budget means the watchdog restarts mid-load (safe — every batch is
all-or-nothing and the cursor/data are on disk — but disruptive). The clients now
chunk at **10k lines** automatically, so a caller who writes `putMany` with a
million rows gets the good behaviour without knowing any of this.

Two corrections to the record, both from this measurement:
- M24's "65 MB per 100k" was real but measured with 10k batches; it is not a
  per-document constant, and a larger batch is disproportionately worse.
- An intermediate reading of "4 MB per 100k" was my harness lying: the split
  files it fed to curl did not exist, so it ingested nothing while printing an
  assumed count. Print the OBSERVED count, never the intended one.

Automatic compaction (`GRANGE_MAX_RUNS`, default 8) was measured separately and
is not part of this cost: with it disabled the ingest curve is identical, and a
full compaction of 400k docs adds ~1 MB.

## Why ingest still costs ~1.1 kB/doc (M28 investigation)

Instrumenting the bulk handler per phase (25k-line batch, 1.5 MB body):

| phase | RSS delta |
|---|---|
| validation (split + two trims per line) | +8 MB |
| direct-run write (partition map, page joins) | +15 MB |
| manifest reload | 0 |

Both blocks are arena-scoped and both reclaim correctly — but RSS does not come
back, because glibc keeps freed pages on its heap free-list and grange allocates
*live* state (run manifests, index state) after each batch, so the freed pages
sit BELOW live data. `malloc_trim` can only release the free top of the heap, so
the scoped-arena trim added in machin #535 helps a process with little live
state (measured flat there) and much less here.

What actually bounds this today: the SDKs chunk at 10k lines, and the RSS
watchdog restarts safely (every batch is all-or-nothing, and the cursor and data
are on disk). The real fix is a write path that never materialises a whole batch
— processing a few partitions per pass over the body, trading passes for peak —
which is a milestone of its own, not a footnote to this one.

Two hypotheses this investigation killed, in order: that the validation pass was
the whole cost (it is a third of it), and that machweb's quadratic body
concatenation was responsible (fixed upstream anyway, and worth it for every
machin web app, but it changed nothing here because curl delivers the body in a
few large reads).

## M29: the streaming write path — what it fixed and what it did not

M28 ended by naming the fix: "a write path that never materialises a whole batch
— processing a few partitions per pass over the body, trading passes for peak".
M29 built exactly that, and the result is worth recording precisely, because
half of it is a negative result.

`cold_bulk_direct` now writes in passes. Each pass takes a slice of the page
range, walks the body from the start, keeps only the records routing into that
slice, writes those pages, and drops everything before the next pass. The pass
width is chosen so a pass holds about `GRANGE_BULK_PASS` (default 5000) records
regardless of batch size, and each pass runs inside its own `arena { }`.

Validation moved INTO that walk. It used to be a separate full pass over the
body (a second parse of every line, ~8-10 MB) whose only job was atomicity — and
it was redundant: a run whose manifest was never written is invisible to
recovery, so aborting mid-write applies nothing. The write path now validates
each record as it routes it, and on a bad line removes the pages it wrote and
returns `-(line+1)` before any manifest exists. Atomicity is unchanged and is
tested directly: a 5000-line batch with one malformed line at 601 is rejected
with `bad op at line 601 (nothing applied)`, the collection still counts 0, and
`verify` reports intact.

Measured, per 25k-record batch:

| phase | M28 | M29 |
|---|---|---|
| validation pass | +10 MB | removed |
| direct-run write | +15 MB | +2.2 MB |

And the negative result: **process RSS for the full 200k ingest did not move**
(222 MB vs M28's 218 MB, ~1.1 kB/doc). Two phases that together accounted for
25 MB per batch now cost 2.2 MB, and the number at the end is the same.

That is consistent with the M28 diagnosis rather than a contradiction of it: the
high-water mark is set by heap FRAGMENTATION, not by any single phase's peak.
Freed pages sit below live state (manifests, index state, the request buffer
machweb allocates per connection), so `malloc_trim` cannot return them, and
lowering a phase's peak does not lower a mark that a different allocation
already set. Reaching a lower number needs an allocator-level change, not a
grange-level one.

Ship it anyway, for reasons that are not the RSS number: peak per pass is now
bounded by `GRANGE_BULK_PASS` instead of by batch size, so a very large batch no
longer scales its own transient cost; and the body is walked once instead of
twice. What bounds ingest in production is still the SDK's 10k chunking plus the
RSS watchdog.

## Route inventory (scripts/routes_test.sh)

Added after an edit to `serve.src` silently deleted the `/watch` route. All six
unit suites passed with it gone — nothing unit-tests the HTTP surface — and the
only thing that caught it was the replication fuzz's remote step, which failed
as "primary unreachable" and looked like a network problem. `make routes` starts
a server and asserts every published route answers something other than "no such
route". It is in `make verify`.

## M30: durability — what "committed" now means

Until M30, grange's crash-safety claim covered exactly one failure mode. `make
crash` kills a writer with `kill -9` and proves the database opens clean and
holds a committed prefix — but a `kill -9` leaves the page cache intact, and the
kernel writes it out afterwards. Nothing in grange called `fsync`, so a power
cut or a kernel panic could lose or tear a commit that had already been
acknowledged. The README said so; it was still the largest honesty gap left in a
product whose first claim is crash safety.

MFL had no `fsync` builtin, so the fix started upstream (machin #536). It takes
a path and syncs a file *or a directory*, because both are needed:

  · `fsync(file)` makes the CONTENT durable
  · `fsync(dir)` makes the file's EXISTENCE durable — creating a file is a
    directory modification, and a fully-synced file can still vanish after a
    crash if its directory entry never reached the disk

grange applies that at two levels. `gr_write_recfile` — the chokepoint every
chunk, page, manifest and index page passes through — syncs content before
returning. The directory is synced at the points that DEFINE a commit: after the
WAL chunk in `gr_commit`, and after each manifest write on the cold paths. One
directory sync covers every entry created since the last one.

This also gives the manifest-last discipline real teeth. It was previously an
ordering of `write()` calls, which the kernel is free to reorder on the way to
the platter; now the pages are fsynced before the manifest that names them is,
so a crash can leave an unreferenced run (invisible to recovery) but never a
manifest pointing at pages that do not exist.

### Cost, measured

| workload | GRANGE_FSYNC=1 | GRANGE_FSYNC=0 |
|---|---|---|
| 200 single-document commits | 1208 ms (165/s) | 834 ms (239/s) |
| one 10k-document bulk | 21 ms | 23 ms |

About 1.9 ms per commit (two fsyncs), so ~31% on per-document commits and
nothing measurable on batched writes — 10k documents are one commit, so the cost
amortises to ~0.0002 ms/doc. That shape is why the default is ON: the way grange
is actually used at scale (bulk ingest through the SDKs) pays nothing for
durability. `GRANGE_FSYNC=0` remains for rebuildable data — a mirror that can be
re-synced from its source, or a benchmark.

### What is proven, and what is not

`make durability` asserts the discipline at the SYSCALL level, because fsync is
invisible to behavioural tests — a build that silently dropped it would pass the
entire rest of the gate. It traces the real calls and checks that a commit
fsyncs its chunk and then its directory, that a cold flush fsyncs every page
before the manifest, and that `GRANGE_FSYNC=0` issues none (which doubles as the
harness's own negative control).

NOT proven: that the storage DEVICE honours fsync. Drives with volatile write
caches can acknowledge a sync that is still in flight. That is a hardware
property and no test on this box can establish it, so the README states it as a
limit rather than implying otherwise.
