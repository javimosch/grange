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
