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

## M31: query cost, and running the hosted instance with a budget

Hosted grange should set a scan budget. Without one, any tenant can hold the
single actor for as long as their largest collection takes to scan, and every
other tenant's request queues behind it (measured: 0.2 ms -> 85 ms).

    GRANGE_MAX_SCAN_DOCS=50000     # refuse a query after 50k documents examined
    GRANGE_MAX_SCAN_PAGES=0        # 0 = no separate page limit

Both default to 0 (unlimited), which is the right default for self-hosted
grange — it is one tenant's own machine, and refusing their own query helps
nobody. The hosted unit file sets them.

Choosing a number: a budget is a latency bound, not a size bound. At roughly
600k documents/second of scanning on dk1, 50k documents is ~80 ms of actor time,
which is the longest another tenant should wait behind one request. Divide the
tolerable queueing delay by that rate rather than picking a round number.

Traceability, as with the fair-use caps: the cost is in every query response
(`scanned`, `pages`) whether or not a budget is set, so a tenant can see which
of their queries are scans before one is ever refused, and a refusal names the
field to index rather than just reporting a limit.

Note the interaction with cold storage: a cold collection's pages are read from
disk, so `pages` counts real I/O; a hot collection's `pages` stays 0 and only
`scanned` grows. A budget expressed in documents therefore behaves consistently
across both, which is why `GRANGE_MAX_SCAN_DOCS` is the one to set.

## M32: the query planner, checked against its own accounting

M31 made every query report what it cost. M32 is what that visibility found when
pointed at the workload grange exists for — an analytics time window.

### The README was wrong in both directions

It said "multi-clause range queries scan". Measured:

| query | hot collection | cold collection |
|---|---|---|
| `ts>=A` | `range` (binary search) | `cold-index`, 25 pages |
| `ts>=A,ts<B` | `scan`, 20,000 docs examined | `cold-index-multi`, 28 pages |

So the claim was already stale for cold collections (M28's intersection work
fixed it and nobody updated the line), and true for hot ones — which is the
wrong way round: the in-memory path was worse at the canonical analytics
question than the disk path.

The fix is bookkeeping, not machinery. Every clause on one range field bounds
the SAME sorted projection, so intersecting them is taking the widest lower
bound and the narrowest upper bound: `rb_bounds_all` folds any number of clauses
into one span, and a window stays two binary searches. Hot windows now report
`mode: range` with 0 documents examined, down from 20,000.

### A limit that was not a limit

`find --limit 5` over a cold window read **120 pages to return 5 documents**.
Cold resolution groups candidates by page and stops APPENDING at the limit, but
kept reading every remaining page and discarding what it resolved. Checking the
limit in the page loop cut data-page reads from ~92 to ~4 (32 pages total, of
which 28 are the window's index pages). The result set is identical — the same
documents in the same order — so this is purely a matter of not paying for
pages whose contents were thrown away.

### And a real bug underneath it

Adding a LIMITED find to the cold-vs-hot differential fuzz immediately failed:
cold returned 4-6 documents for `--limit 3` where hot returned 3. The memtable
branch of `cold_idx_resolve` appended candidates with no limit check at all, so
any cold collection with unflushed matching writes over-returned. Reproduced
against the pre-M32 binary (6 items for a limit of 3), fixed, and covered by a
regression test that was confirmed to fail without the fix.

Worth noting how it was found: this bug is invisible to a count (counts must see
every match, so the limit does not apply), invisible to a hot collection, and
invisible to any test that only checks the documents it got back are correct —
they were correct, there were just too many of them. It took an oracle that
compares two implementations of the same query.

## M33: ordered queries ("the latest N")

M32 made `limit` cheap. It did not make it USEFUL: `find ts>=A,ts<B --limit 5`
returned the five EARLIEST events in the window, because a limit without an
order is an arbitrary subset. A dashboard asking "what just happened" had to
fetch the whole window and sort it client-side.

`?order=<field>&desc=1` (`--order`/`--desc` on the CLI, `order`/`desc` in every
SDK) fixes that, and needs no new index — both storage modes already keep the
data sorted for range queries:

  · hot  — the projection is already ascending; ordering is the same [lo,hi)
           span walked forwards or backwards
  · cold — a range index is sorted pages plus min/max boundaries; collect the
           span's (value, id) pairs, sort once, resolve in order, stop at the
           limit

Measured, 20k documents, "latest 5 in a 2000-wide window": 5 documents examined
where the unordered equivalent examined the whole window. On cold, 7 pages for 5
documents.

Requirements and costs, stated plainly:

- Ordering requires a `--range` index on the ordering field. Asking without one
  is refused with the exact command to declare it, in the style of the scan
  budget's error.
- On cold, ordering materialises the SPAN's index entries before sorting them.
  Bounding the window keeps that small; ordering an entire large collection does
  not. Set `GRANGE_MAX_SCAN_DOCS` if callers might try.
- Ties break by id, making this a TOTAL order. That matters beyond neatness:
  with an unspecified tie order, paginating by (value, limit) can show one
  document twice and skip another.

### What the ordered oracle caught

Ordering is the first query whose ORDER can be compared between storage modes —
every earlier observable in the cold-vs-hot differential fuzz was a count or a
single document, because an unordered find may legitimately return the same
documents in a different order. Adding an ordered observation immediately found
a real bug: a document updated from v=65 to v=57 DISAPPEARED from cold results.
Its stale index entry was consumed by the dedup set before the staleness check
rejected it, so the correct entry at its new position was then suppressed. The
id is now marked seen only when its entry is ACCEPTED.

It also flagged tie order differing between hot and cold, which is what prompted
making ties a total order rather than papering over it in the harness.

## M34: the second request

M33 shipped an ordered-query crash. One ordered query worked perfectly; the
SECOND one segfaulted the server, deterministically, on any hot collection whose
sorted projection had not yet been built in that process.

The cause is a memory-lifetime bug that safe MFL is currently able to express.
`rb_ensure` builds the sorted projection into whatever arena is current and
stores it in a GLOBAL. The `/find` handler wraps the query in a per-request
`arena { }` — deliberately, so page reads and response strings are reclaimed —
so a projection built inside that block was freed when the request ended, and
the next request read freed memory.

`q_warm` exists precisely to build such state BEFORE the arena, and it warms the
fields named in a `where` clause. `order=` was a new way to reach a range index
that never went through it. The fix is one call (`ord_warm`) before the arena.

### Why the whole gate missed it

Every existing harness is blind to this shape:

  · the unit suites and both fuzzes call the query functions in-process, with
    no request arena around them at all
  · routes_test.sh makes ONE request per route, then tears the server down
  · isolation / durability / caps each start a fresh server for their own check

Nothing anywhere issued the same request TWICE against one process. That is the
signature of every arena/global lifetime bug — the class a single long-lived
actor is most exposed to.

`scripts/soak_test.sh` (`make soak`) closes it: one server, every route, four
rounds, with writes in between, asserting the server stays alive and that
identical calls give identical answers. Two details are load-bearing, both found
by watching the harness FAIL to catch the bug it was written for:

1. **It restarts the server mid-run.** Lazily-built state is already warm in the
   process that declared the index, so a single-process soak silently tests the
   easy path. After a restart, the first query is the one that BUILDS it. The
   RSS watchdog restarts this server in production, so this is the normal case.
2. **It issues a cold-start ordered query explicitly, first.** Relying on route
   order hid the bug entirely: a range `where` query earlier in the list warms
   the projection outside any arena.

With the fix reverted, the harness now reports `Segmentation fault` and names
the request that caused it.

### Upstream

machin's ARENA001 is meant to catch exactly this, and does — but only when the
assignment is lexically inside the arena block. Moved one function call deeper
it is silent, and the program returns wrong data with exit 0. Filed as
machin#539 with a minimal repro. `escape()`, the tool for promoting a value out
of an arena, is only valid lexically inside an arena block, so a callee cannot
defend itself; caller discipline is the only defence available today.

Audited the rest of grange for the same shape: `/find`, `/count` and `/agg` all
warm before their arena. `q_warm`'s condition was tightened to match the one the
query path uses to WANT the projection — it previously required an extra
`ix_is_indexed` conjunct, so two predicates in two files had to stay in
agreement with a use-after-free as the penalty for drift.

## M35: keyset pagination

M33 gave "the latest N". M35 gives "and the N after that", which is what makes
an ordered query usable for anything that walks data rather than peeking at it.

An ordered response now carries `next`, a cursor of the form `<value>|<id>` —
the sort key of its last row. `?after=<cursor>` resumes strictly past it in the
query's direction. `next` is omitted when the page came back short, so a caller
knows to stop without an extra round trip.

### Why keyset rather than offset

`offset=N` has to walk the N rows it skips, so paging through a collection is
quadratic overall and page 500 costs 500x page 1. A cursor is a seek: on hot
collections a binary search on the FULL sort key (`rb_seek_key`), on cold ones
an extra bound that prunes index pages by their recorded min/max, so pages
already paged through are not re-read. Every page costs about the same.

Correctness matters more than the cost, though. An offset names a COUNT of rows;
a cursor names a POSITION IN THE ORDER. With an offset, a row inserted before
your position shifts everything down and you see a row twice; a deletion makes
you skip one. A cursor is immune to both.

This is what M33's tie-break bought. A cursor of `<value>` alone cannot place
itself among documents sharing that value, which is exactly where a page
boundary is most likely to fall. Because the order is total, "the position just
past this key" is a single well-defined index.

### The honest limit

A document MODIFIED between pages moves in the order, so it can be seen twice or
missed. That is inherent to reading a changing collection without a snapshot,
and no cursor scheme fixes it. Rows that are inserted, deleted, or untouched
elsewhere are unaffected.

### Verification

`scripts/pagination_test.sh` (`make pagination`) walks entire collections page
by page and asserts the concatenation is element-for-element identical to the
one-shot ordered answer: both storage modes, both directions, page sizes chosen
to land INSIDE runs of equal values, with and without an extra where-clause, and
inside a bounded window. Plus an independent count that every document came back
exactly once.

The negative control is worth recording, because it shows the harness has teeth
and that M33's tie-break was load-bearing rather than cosmetic. With the
tie-break removed from the merge sort:

    FAIL hot/desc: pages of 13 reproduce the full order —
         paged=282 oneshot=300 dups=[k082 k083 k104] missing=[k023 k037 k038]

Documents both duplicated and lost, exactly as an unstable order predicts.

## M36: index builds that fit in the budget

Declaring a range index collected every (value, id) pair of the field into
memory, sorted them, and wrote the sorted pages — the one operation whose cost
scaled with the COLLECTION rather than with a page, and the README said so.
Measured on 200k documents: RSS 82 MB -> 257 MB.

The failure mode under the hosted 100 MB budget is worth stating precisely,
because it is not the obvious one. The build SUCCEEDS and answers the request;
then the RSS watchdog fires and restarts the process:

    {"event":"rss_restart","rss_kb":266080,"max_mb":100,"loaded":3}

So the tenant who declared the index gets their index. Everyone else on the
shared server gets their in-flight request dropped. It is M31's isolation
problem again — one tenant's work paid for by all the others — in memory rather
than latency.

`src/coldsort.src` replaces it with an external sort: walk the data pages
accumulating pairs, spill a sorted run every `GRANGE_SORT_SPILL` (25k) pairs,
then k-way merge the runs holding ONE PAGE of each in memory, emitting the final
index pages as the merge produces them. Spill files are deleted afterwards, and
the boundary file is still written last, so an interrupted build leaves
unreferenced pages rather than a corrupt index.

### The measurement that changed the design

The external sort ALONE made things worse: +295 MB against the in-memory path's
+176 MB. It holds less live memory but allocates more in total — it writes the
runs and reads them back — and in the long-lived actor nothing is reclaimed
until the goroutine returns, which it never does. The fix only works inside a
scoped `arena { }`:

| 200k documents | build RSS delta |
|---|---|
| in-memory (old) | +160 MB |
| external, no arena | +295 MB |
| external, scoped arena | **-11 MB** (it drops: the arena returns the pages) |

Scoping is safe here for the reason machin#539 is dangerous: the build stores
nothing that outlives it. It writes files and returns an int. The only globals
it touches are the query cost counters, which are scalars, not pointers into the
arena.

Under a 100 MB budget the same 200k build now completes with zero watchdog
restarts, the server stays up, and ordered queries work against the result.

### Verification

`scripts/indexbuild_test.sh` (`make indexbuild`) builds the same index both ways
against identical data in one run and asserts the output is BYTE-IDENTICAL —
same file names, same bytes, no spill files left behind — then that the external
path costs under half the memory, then that a build under a tight budget causes
no restart and produces an index that answers ordered queries. It repeats the
identity check with 3000-entry spills so the k-way merge is exercised at depth
rather than with two or three runs.

The harness lied on its first run, in the way this project has been caught
before: `/bulk` caps a request at 50000 ops, so a single POST of a 200k fixture
was REJECTED, both builds indexed an EMPTY collection, both reported 2 MB, and
the byte-identity check passed by comparing two empty indexes — in 7 seconds.
Seeding now chunks the load and ASSERTS THE OBSERVED DOCUMENT COUNT, which is
the only thing that turns a seeding bug into a failure instead of a fast pass.

machin's Falsifier also earned its place during this milestone: it flagged
`cs_cleanup(rid, field, nruns, runpages)` as an out-of-range read for
`nruns=1, runpages=[]`. No caller passes that, but it is a signature with two
parameters that must agree; the length is now the count.

## M37: the count that allocated the collection

README item: "Per-request arena scoping is the next engine milestone." Before
attempting it, M37 measured what a request actually retains. A long-lived server
holds some memory per request — the single actor's arena is reclaimed only when
the goroutine returns, which it never does — so the question is how much, and
whether any of it scales with the data.

Measured on a 20k-document collection, RSS delta per request:

| request | kB retained |
|---|---|
| `/health` (no collection, no query) | 8 |
| `/count?coll=h` (no filter) | **71** |
| `/count?coll=h&where=site=a.io` (indexed) | 10 |
| `/get?coll=h&id=k5` | 10 |
| `/find ... limit=20` | 16 |
| `/find ... limit=100` | 34 |

An unfiltered count cost SEVEN TIMES an indexed one. `gr_count()` was
`len(keys(g_mem))`, and `keys()` materialises every key just to count them: 20k
strings allocated and retained, per request, for the simplest operation the
database has. `len(map)` is O(1) and allocates nothing. The same idiom was on
two more hot paths — the cold-threshold check runs on EVERY COMMIT, and
`cold_stable()` runs on every cold query — plus four cooler ones.

After the fix, an unfiltered count is 10 kB/request and no longer varies with
collection size.

Nothing caught this because every other harness measures ANSWERS, and the answer
was always correct. `scripts/retention_test.sh` (`make retention`) measures
memory instead: it asserts an unfiltered count costs about the same on 1k and
20k documents (the shape, by comparison, not an absolute number), and that no
route exceeds a per-request ceiling. Its negative control: restore
`len(keys(...))` and it reports `11 -> 71 kB`.

### Why the per-request arena is still not wrapped

The accept loop carries a note explaining that it cannot be wrapped in an
`arena { }` because `gr_use` stores request-derived strings (`g_db`, `g_coll`,
registry keys) into globals deep in the call chain. That is still true, and M37
found the second half of the reason: handlers `escape()` their response body OUT
of the handler's arena into the long-lived one, so the body is retained even
though the query that built it was reclaimed. Wrapping the loop would fix that —
and would also, today, leave `g_db`/`g_coll` dangling.

Making it safe needs either interprocedural ARENA001 provenance (machin#539, so
the hazard is a compile error rather than a segfault found in production) or an
`escape()` usable in a callee. Until then the honest position is: the remaining
~8 kB/request baseline is bounded by the RSS watchdog, and the thing that
mattered — a cost that grew with the data — is fixed and guarded.

One safe piece was scoped: `srv_write_res` built headers plus a full COPY of the
body before writing. Nothing there outlives the syscall, so it is now inside an
arena. Worth ~1 kB/request, measured, and recorded here so nobody re-derives it
expecting more.

Also fixed: `/stats` reported `rss_kb` on cold collections but not hot ones, so
an operator watching a hot deployment had no memory signal from the API. It
reports it on both now — the omission cost a measurement during this milestone.

### The same bug on the branch production actually uses

The fix above was measured on a HOT collection, deployed, and then measured on
the live server — where an unfiltered count still retained **82 kB per request**.
The hosted workload is COLD, and `cold_count_all()` read every page group to
count. Fixing the hot branch and validating it on hot data left the deployed
path untouched.

A stable cold collection (one run, nothing unflushed, no tombstones) has every
id exactly once and its manifest already records how many, so the count is
arithmetic with zero page reads: **82 kB -> 2 kB per request**. Anything else
falls back to the scan, because ids can be shadowed across runs or deleted and
summing manifests would overcount.

The first version of that shortcut used the manifest's `count`, and the hot/cold
differential fuzz rejected it on the second operation: cold said 1 where hot
said 0. A flushed run stores tombstones as RECORDS, so `count` includes deleted
documents. Manifests now carry a separate `live` figure, written by all three
paths that produce a run. Old manifests have no such field, are read as -1, and
fall back to scanning — verified against a database written by the previous
binary.

That introduced the hazard machin's Falsifier warned about in M36: two parallel
arrays that must agree. Every site that appends or resets the run counts now
does both, and the shortcut additionally refuses to use `live` unless its length
matches the run list — so a future missed site degrades to a scan instead of
answering with a stale number.

`scripts/retention_test.sh` now measures a COLD collection too. Testing only the
hot shape is what let an 8x regression reach production in the first place.

### ...and the shortcut still did not help production

Deployed, the live count was STILL 83 kB per request. The stable-run shortcut
needs exactly ONE run, and the mirror accumulates several between compactions,
so it fell straight through to the scan. Two fixes in a row, both measured on
shapes production does not have.

A cold collection's count changes only when documents are written, and every
committed record advances `g_seq` — so `g_seq` is a version stamp the count can
be cached against, keyed by (db, coll, seq). A mirror that syncs every few
minutes and is counted in between now pays for the scan once per sync instead of
once per request.

The cache is also invalidated explicitly in `gr_refresh`, because a FOLLOWER's
data changes when the primary's files change, which does not go through this
process's commit path and so may not move `g_seq`. A stale count on a replica is
a silent wrong answer, which is worse than the scan it saves.

Validated by the two differential fuzzes, which compare counts after every
operation including deletes, flushes and compactions (7200 ops), and by the
replication fuzz for the follower path.

#### Measuring on production is not free, and I polluted my own numbers

The post-deploy reading of "83 kB, then 23 kB" per request was taken by firing
200-request bursts at the live server — which trips its own fair-use cap (300
requests/minute, M15). Once the limiter engaged, `/stats` stopped returning data
and the deltas became meaningless (one probe reported a NEGATIVE per-request
cost). Production is a rate-limited multi-tenant service; it is not a benchmark
rig, and burst-probing it measures the limiter.

The honest figures come from reproducing production's SHAPE locally — a cold
collection with five runs, which is what the mirror looks like between
compactions:

| | bytes/request |
|---|---|
| request baseline (`/health`) | ~7-8 k |
| unfiltered count, cache warm | 11.7 k |
| count alternating with writes (cache always invalidated) | 42.6 k |

So a repeated count now costs little more than the request itself, and the scan
is paid once per write batch rather than once per request. Counts verified
correct in both states (10000, then 10100 after 100 writes).

## grange as a library: the poche contract

grange has two consumers and only one speaks HTTP. **poche**, an agent-first
headless CMS, compiles grange's engine modules directly into its own binary and
calls `gr_use`/`gr_put`/`q_find` in-process — its own README describes the stack
as "poche (CMS) → grange (engine) → machin", and it builds against
`../grange/src` directly rather than vendoring a copy.

That consumer was broken and nobody noticed. Milestones added cross-module calls
(`query` → `qcost`, `cold` → `coldindex`/`coldrange`/`coldsort`) until the subset
poche links stopped compiling at all:

    error: [undefined-field] cold_flush: undefined variable "g_cifields"

Nothing in the gate compiles a subset, because grange always builds all of
itself. `scripts/embed_test.sh` (`make embed`) now pins the contract: the
embeddable core must compile alone, and must work driven as a library — open,
write, index, count, ordered query, and `gr_reset()` in a loop. poche's build
list and this harness's `CORE` list are the same set, and drift now fails here
instead of silently in poche.

### What each side owes the other

**poche → grange.** poche solved a problem grange documented as unsolved. Its
serve loop calls `gr_reset()` every N requests to keep RSS flat — grange HAS
`gr_reset()` (registry.src) and never calls it. M37 concluded the per-request
baseline was bounded only by the RSS watchdog restarting the process; poche's
answer is gentler and lives inside the same engine. Adopting it in `grange serve`
is a candidate milestone, gated on the same conditions poche uses.

**grange → poche.** poche hand-rolls what grange now does natively:
`query_page.src` sorts candidate ids in memory (`query_sort_ids`) and paginates
by OFFSET. grange has ordered queries on a range index (M33) and keyset
pagination (M35). The offset approach has exactly the defect M35 documents — a
row inserted before your position shows one document twice, a deletion skips one
— and the in-memory sort is the cost keyset pagination avoids. poche also
predates fsync durability (M30), the cold `find --limit` over-return bug (M32),
and query cost accounting (M31).

### gr_reset() invalidates the CALLER's values too

Writing the harness demonstrated the contract by breaking it. The first version
compared a count read BEFORE the reset against one read after, and printed:

    FAIL: count changed after reset: 60 != 0<garbage>

`gr_reset()` frees the arena, so anything the caller still holds dangles — not
just grange's internals. Call it where nothing is in flight: after the response
is written, with no parked watchers and no staged writes. poche does exactly
that; the requirement was simply never written down. It is now, on the function.

One related change, described honestly: `gr_reset()` did not clear the M37 cold
count cache, which holds the db and collection names it was computed for — so
the next count compared against freed memory. That is undefined behaviour and is
now fixed, but I could NOT construct a case where it returned a wrong answer:
the cache's sequence guard rejected every scenario I tried, including opening a
different collection after a reset. Hygiene, not a demonstrated bug.

## M38: reclaiming the arena instead of restarting the process

M37 ended with grange's only answer to per-request retention being the RSS
watchdog restarting the process — which drops every in-flight request and every
parked watcher. poche, which embeds this same engine, already does something
gentler: it calls `gr_reset()` every N requests. grange HAS `gr_reset()` and
never called it.

`GRANGE_RESET_EVERY=<n>` enables it, **off by default**. The reset runs only
between requests, with nothing staged, no watcher parked, and after the response
is written.

### What survives an arena reset (measured, and narrower than it looks)

`gr_reset()` calls `arena_reset()`, and what stays valid across that is:

| | survives |
|---|---|
| string literals | yes |
| `env()` values | yes |
| `args()` values | yes |
| **computed strings** | **no — silently corrupted** |

A concatenated `"tok-secret123-end"` came back as `"1"`. No crash, no
diagnostic. So anything re-derived after a reset must come from `args()`/`env()`
DIRECTLY — including the db path and token, which cannot be read back from the
parsed flag struct, because that struct's own maps are computed.

Two consequences, both implemented:

- the db path and token are re-derived from argv/env after each reset
- a GENERATED token (`to_hex(rand_bytes(16))`, when neither `--token` nor
  `GRANGE_TOKEN` was given) is a computed string and cannot be re-derived, so
  periodic reset stays disabled in that case rather than corrupting auth

### The bug this exposed

`g_nl` — `bytes("\n")`, the separator every page, chunk and index walk searches
for — is the engine's ONLY computed global. `arena_reset()` freed it, so after a
reset every line-walk searched for garbage: pages read as empty and `verify`
reported "malformed page records" on files that were perfectly fine. Counts
stayed correct throughout, because they answer from the manifest and never walk
a page, which is exactly how it hid.

It is re-initialised inside `gr_reset()` rather than at the call site, so
EMBEDDERS get the fix: poche calls `gr_reset()` every N requests and walks pages
through this same code.

### Why it is off by default

The memory result is real but workload-dependent, and the two measurements
disagree in a way worth recording rather than averaging away:

| 6000 requests, one 20k collection, sampled every 500 | RSS |
|---|---|
| no reset | 46 → 126 MB (would trip a 100 MB budget) |
| reset every 400 | 23 → 61 MB |

| 4000 requests, three collections, sampled every 100 | peak RSS |
|---|---|
| no reset | 86 MB |
| reset every 400 | 105 MB |

Both are true. A reset drops the collection, and the next request RELOADS it, so
the sustained level falls while transient spikes proportional to the collection
size appear. Fine sampling catches those spikes; coarse sampling does not. An
earlier "39 → 36 MB, flat!" reading of mine was the same artifact in the other
direction — the endpoint happened to land just after a reset.

Latency cost is small: 3.98 ms/request with no resets, 4.50 ms at the extreme of
one reset per 25 requests on a 20k collection.

So the operator opts in, with the numbers above to decide from.
`scripts/retention_test.sh` asserts CORRECTNESS across resets — data intact,
auth still enforced, cold pages still walkable, export still complete — and
prints the memory numbers without asserting a winner, because encoding a
workload-dependent claim as a test would be a lie in test form.

## M40: read replicas — one writer, N readers, one directory

`grange serve` is single-actor, so on one server an expensive query is paid for
by everyone behind it: M31 measured an 0.2 ms get becoming 85 ms while ONE
unindexed scan ran, and bounded it with scan budgets rather than removing it.
The doc named replicas as the honest fix, because the mechanism already existed
and the replication fuzz already exercised it.

    grange serve --db /data/db --port 8801 --token $TOK             # writer
    grange serve --db /data/db --port 8802 --token $TOK --follow    # reader
    grange serve --db /data/db --port 8803 --token $TOK --follow    # reader

Same directory. A `--follow` server is read-only — it REFUSES writes, which is a
safety property rather than a nicety: two writers on one directory would corrupt
it. Route writes to the writer port and reads to the readers.

### What this buys, measured

30k-document cold collection, an unindexed scan looping on replica1:

| | get p90 |
|---|---|
| replica2 (idle baseline) | 0.3 ms |
| replica2, while replica1 scans | **0.4 ms** |
| primary, while replica1 scans | **0.3 ms** |
| replica1, which is serving the scan | 25.5 ms |

The expensive query is confined to the replica serving it. On a single server the
same workload took an 0.2 ms get to 85 ms.

### Staleness: better than async replication, and here is why

A local follower re-reads from disk on every request, and a write is fsynced
before the primary acknowledges it (M30). So a read issued AFTER an acknowledged
write sees that write: 30 out of 30 writes were visible on a replica on the very
next request, with no wait.

That is a property of THIS topology — followers over the same directory. It does
NOT extend to `grange follow`, which pulls from a remote primary over `/watch`
into its own directory and is genuinely asynchronous. Use same-directory
followers for read scale-out on one host; use `grange follow` for a replica on
another machine, and expect real lag there.

The guarantee also depends on the client waiting for the write's response. A
client that fires a write and reads a replica without waiting can miss it.

### Deploying it

dk1 already has the app registered from an earlier experiment
(`grange-read` → `read.grange.intrane.fr`, port 8802). A replica needs the same
`--db`, the same `--token`, and `--follow`; give it its own systemd unit with
`Restart=always`, exactly like the writer.

Two things not to do:

- do not point a replica at a COPY of the directory — it must be the same one,
  or it serves stale data forever
- do not give a replica `GRANGE_RESET_EVERY` and a generated token: the token
  cannot be re-derived after an arena reset (M38), and the reset is disabled in
  that case anyway

`scripts/replicas_test.sh` (`make replicas`) asserts all of it: replicas agree
with the primary, refuse writes, receive writes promptly, and that a scan on one
replica leaves the others and the primary alone — plus that the replica serving
the scan DOES slow down, without which the isolation checks would be vacuous.

## M41: making the guide tell the truth, and keeping it that way

grange is agent-first, so `grange guide` IS the interface documentation. It had
drifted, silently, for ten milestones:

- it reported **version 0.1.0**
- it stated **"no fsync builtin yet — OS-crash durability is best-effort"**,
  which M30 had made false and asserted false at the syscall level
- it listed **12 of 19 verbs**, omitting cold storage, range indexes, ordering,
  pagination, cost accounting, scan budgets, replicas, verify, watch, bulk and
  export

An agent reading that was actively misled — told the database was not durable
when it is, and unaware of half the product. Nothing caught it because nothing
compared the guide against the source.

### The guide is generated now

`scripts/gen_guide.py` holds the content and writes `cmd_guide` / `cmd_help_json`
into `src/cli.src`. Eight kilobytes of hand-escaped JSON inside MFL string
literals is how it rotted in the first place; the version now lives in one place
(`grange_version()`) rather than being duplicated in both documents.

Writing the generator produced its own lesson: the first chunker split a `\"`
escape across two string literals, which the compiler reported as unbalanced
braces a hundred lines away. It now refuses to end a chunk on an odd run of
backslashes, and self-checks that the chunks rejoin to the original.

### The guard

`scripts/guide_test.sh` (`make guide`, in `make verify`) fails when anything in
`src/` is absent from the guide: every verb the CLI dispatches, every HTTP route
the server answers, every `GRANGE_*` variable the code reads. It also pins the
two claims that were WRONG rather than missing, so they cannot return, and
checks that `guide` and `help-json` agree on the version and the verb list —
they had drifted apart too.

It is deliberately mechanical: it cannot check that the prose is TRUE, only that
nothing is missing, which is the failure that actually occurred. Verified
against the old guide, where it reports every missing verb.

### In-repo skills

`skills/grange-query`, `skills/grange-operate`, `skills/grange-embed` — so a
future session picks this up via `skills_match` instead of re-deriving it. They
carry the things that cost time to learn: read the `mode`/`scanned`/`pages`
fields, ordering needs a `--range` index, pagination is keyset, `gr_reset()`
frees what the CALLER holds, check WHICH binary answered, and do not burst-probe
a live instance because the rate limiter makes the numbers meaningless.

## M44: the published SDKs, and the 500-line rule

### An SDK version meant two different things

grange shipped ordering (M33), keyset pagination (M35) and projection (M43),
adding each to all four SDKs. None of it reached anybody. Unpacking what the
registries actually serve:

| | npm / PyPI `grange-db` 0.11.0 | repo |
|---|---|---|
| `order` | 0 occurrences | yes |
| `after` | 0 occurrences | yes |
| `fields` | 0 occurrences | yes |

The newest Go tag was `sdk/go/v0.10.0`, so `go get …@latest` predated all three
too. And the repo was ALSO labelled 0.11.0 — one version number naming two
different bodies of code, which registries will not let you fix by republishing.

The v0.11.0 release note said "All four SDKs take `fields`". True of the
repository, false of anything installable. That note has been CORRECTED in place
rather than quietly patched: it now says which versions carry it, and that the
HTTP API works regardless of SDK version.

Repo SDKs are 0.12.0, verified end-to-end against a live server — ordered plus
projected queries and cursor paging, in node, python, Go (`FindFields`) and
machin (`grange_find_fields`). `sdk/go/v0.12.0` is tagged, which is all a Go
consumer needs. npm and PyPI require credentials this machine does not have.

`scripts/sdk_version_test.sh` (`make sdkversion`) fails when the repo's SDK
version equals the published one but the sources mention features the published
artifact lacks, and checks the Go tag the same way. Offline it SKIPS rather than
passes — a check that silently succeeds when it cannot reach what it checks is
worse than no check. Negative control: pinned back to 0.11.0 it reports exactly
the state that shipped.

### Every file is under 500 lines again

The project's rule is 500 lines per file. Four files had drifted past it, and I
had deferred fixing that five times, each time noting it would keep
not-happening unless it was the milestone. It was the milestone.

| | before | after |
|---|---|---|
| `cold.src` | 585 | 446 (+ `coldbulk.src` 146) |
| `serve.src` | 580 | 431 (+ `servemeta.src` 68, `servebulk.src` 123) |
| `engine.src` | 562 | 409 (+ `recfile.src` 160) |
| `coldindex.src` | 518 | 431 (+ `coldquery.src` 232) |

Every cut follows a concern, not a line count: record-file format and durability
out of the engine; bulk ingest out of both the cold path and the router; account
routes out of the data routes; index READING out of index BUILDING.

One cut was wrong and the compiler caught it: extracting the "meta" routes from
`serve.src` took the authentication gate with them, and everything downstream
depends on `role`/`tid`. The second attempt cuts deliberately BELOW auth, and
says so in the file, because the next person will be tempted by the same
boundary.

The harnesses earned their place again: `make routes` after every split, and
`make embed` caught that poche's build list needed the four new files — which
is exactly the drift that broke poche silently before it existed.

### The split that broke production

The `serve.src` cut shipped a regression. Extracting the account routes carried
this with them:

```
if role == "tenant" {
    ...
    root = tn_root(tid) + "/" + dbname
}
```

That resolves a tenant's data directory, and in a callee taking `root` BY VALUE
it assigns a copy that is discarded on return. Every tenant data request then
opened the ADMIN root instead. On dk1 that surfaced as `stats` reporting
`docs: 0` for a collection holding 1123 documents, and ordering failing with
"needs a range index" on a collection that had one.

The data was never at risk — the CLI read all 1123 documents from the same
directory throughout, which is how I knew within a minute that this was a
resolution bug and not corruption.

**Why the gate missed it.** Every harness drives a single-tenant server with
`--db`. Nothing performed a tenant DATA query, so the entire tenant path — the
one the hosted product runs on — was untested beyond signup and rate limits.
`caps_test.sh` now stores and reads a tenant's own data across two databases,
and asserts it lands under the tenant's root on disk.

**And a lesson about the negative control.** Write-then-read cannot detect this:
with the root misresolved, writes and reads use the same wrong directory and
agree perfectly. What catches it is the second database — with the bug, both
resolve to the same root and the second sees three documents instead of one.

Two of my attempts at that control were themselves broken: one removed the wrong
`if role == "tenant"` block, and one built with output suppressed so a failed
build left the good binary in place and everything "passed". Injecting the exact
production failure — commenting out the one assignment — is what finally proved
the harness works.

## M45: backups that exist

The v0.9.0 release notes said "Nightly backups." There were none: no timer, no
cron entry, no backup directory on the host. The claim was written before the
mechanism existed and never became true — the worst kind of production gap,
because everyone believes it is covered. That note has been corrected in place,
like the SDK claim in M44.

    scripts/backup.sh --db /data/db --out /backups/grange --keep 7

Copy, verify, prune — in that order.

### Why a plain copy is a valid backup here

A grange database can be copied WHILE it is being written, and that follows from
the format rather than from luck: every `.grg` file is written exactly once and
never mutated, a cold run's manifest is written LAST, and recovery drops a torn
final chunk. So the worst a concurrent write can do to a copy is leave a chunk
recovery discards — the same all-or-nothing commit boundary `make crash` proves.

Measured under continuous writes: source 165 documents, restored 162, every one
whole and the restored database writable.

What makes it a backup rather than a copy is the verification. Every collection
in the copy is checked with `grange verify`, which walks each file's checksum and
record stream, a cold manifest against its pages, and the declared indexes. A
corrupt source exits 92, and the failed copy is KEPT rather than pruned —
deleting the evidence of a failed backup is how you find out about it much later.
Pruning happens only after a good backup exists, so a run of failures never
empties the retention window.

### Tenant databases are the ones that matter

They live in a sibling `<db>.tenants` directory, so the obvious `cp -a $DB`
silently omits every paying customer. The script takes both.

The first version put the tenant roots BESIDE the stamped directory, which made
one backup look like two entries to the retention pass — it would have pruned
half of a backup. The layout is now `<stamp>/<name>` and
`<stamp>/<name>.tenants`, mirroring the source so a restore is a copy back into
place with no renaming, and the harness asserts that one backup is one retention
entry.

### On dk1

`grange-backup.timer` at 03:30 UTC, `Persistent=true`, keeping 7. Verified
against production data: the restored copy of the live analytics mirror counted
1160 documents against the source's 1160, and `verify` reported it intact.

## M46: liveness is not readiness

grange was already monitored — perrus polls `/health` on the primary and the read
replica every 60 seconds, with Telegram alerting configured. That check answers
"up" as soon as the accept loop is running, and stays green through:

  · a data directory that has gone read-only
  · recovery having quietly dropped chunks on the last open
  · RSS about to trip the watchdog (a restart drops in-flight requests and
    parked watchers)
  · the nightly backup having stopped weeks ago

Which is to say: it would not have noticed the M45 gap. `GET /ready` answers
those, returns **503** when any of them is true, and lists what is failing. It
reads no pages and runs no verify — a readiness probe that costs real work is the
thing that eventually takes the server down.

Deliberate choices worth keeping:

- **`/health` stays trivial.** Two endpoints, two purposes; merging them would
  force every 60-second poll to pay for the deep check.
- **No backup marker reports `null`, not a failure.** Plenty of deployments have
  no backup job, and a false alarm teaches people to ignore the endpoint.
- **`/ready` requires a token.** It reports RSS, version, collection count and
  backup age — operational detail, not something to publish on a paid
  multi-tenant service. That is why the checker runs on the host rather than
  perrus polling it.

### The alerting is the point

`scripts/readycheck.sh` runs from a timer every 15 minutes and messages Telegram
**only on transitions**, reporting recovery as well. A check that messages every
15 minutes while something is wrong gets muted, which is worse than not alerting.
It also distinguishes `down` (no response at all) from `failing` (responding, but
sick) — conflating those sends a misleading page.

One honesty fix while testing it: the JSON reported `alerted: true` on the very
first observation, when it deliberately sends nothing. It now reports
`transition` (the state changed) and `notified` (a message was actually sent)
separately.

Verified end to end on dk1: the first timer run caught a restarting server as
`failing`, the next saw `ok`, and the transition sent a recovery notice.
`/ready` on the primary reports `backup_age_hours: 0` against the nightly job,
and the replica correctly reports `role: follower`.

## M47: the agent journey, walked end to end

Every other harness tests a capability. This one tests the PRODUCT: the path a
stranger's agent actually walks, using only what the published contract tells it,
in the order the contract tells it — find the URL, read `/llms.txt`, mint a
payment-rail wallet, sign up, write, index, query, and check the bill.

That path crosses the parts nothing else covered: the unauthenticated contract,
tenant signup, the per-tenant data root, metering, and the client SDK.

**Walked against the live instance**, not just locally: minted a real peage
wallet, signed up at grange.intrane.fr, wrote two documents, declared a range
index, ran an ordered + projected query (`mode: range-ordered`), and read
`/usage` — 134 bytes against a 52,428,800-byte free allowance, `accrued_cents: 0`.
Then the same queries through `pip install grange-db`, which the contract
advertises and which was only publishable an hour earlier.

`make journey` runs it against a local server; `--live` walks the hosted one.

### Three versions of one check were theatre

The check "every route the contract advertises exists" took four attempts, and
the failures are instructive because each *passed* while proving nothing:

1. **Grepping `/llms.txt` for route names.** Removing the documented `COUNT`
   entry still passed, because `/count` appears in unrelated lines.
2. **Probing every route with GET.** Reported six healthy POST-only routes as
   missing.
3. **Extracting the method with `(-X POST )?\$G/…`.** The contract writes
   `-X POST "$G/bulk?…"` with a quote between the method and the URL, so those
   were classified GET and reported missing.
4. **Renaming a documented route to `/counter` as a negative control.** Still
   passed — and that one was not the harness's fault (below).

It now extracts each advertised route WITH its documented method, probes 18 of
them, and a control that renames one to `/zzznope` fails as it should.

### grange routes by prefix, so a typo silently succeeds

Attempt 4 failed because `/counter` genuinely answers: most routes match with
`has_prefix(req.path, "/count")`, since `req.path` carries the query string. So
`/counter` and `/countXYZ` both return a count, while `/healthzzz` correctly
404s because `/health` is matched exactly.

An agent that typos a route gets a plausible answer and never learns. That is
worth fixing, and it is the next milestone rather than a footnote here.
