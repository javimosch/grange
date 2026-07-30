---
name: grange-operate
description: Run a grange server — durability, memory limits and the RSS watchdog, read replicas, integrity checking, cold storage, and the hosted multi-tenant setup. Use when deploying, sizing, debugging or scaling a grange deployment.
---

# Operating grange

`grange guide` is version-exact for the binary in front of you. This skill is
the operational knowledge that is not obvious from the flags.

## Running it

```sh
grange serve --db /data/db --port 8801 --token "$GRANGE_TOKEN"              # writer
grange serve --db /data/db --port 8802 --token "$GRANGE_TOKEN" --follow     # read replica
```

Always under a supervisor with `Restart=always`. Two failures on this estate
came from processes started by hand: one nohup that died silently, and one
follower still running **1 day 13 hours later on a stale binary**, holding the
port so the real unit crash-looped on `Address already in use` while probes hit
the old process and looked fine. **Check which binary answered, not just that
something did** — compare a `mode` string or the version in `guide`.

## Durability

A commit is fsynced before it is acknowledged: the chunk, then the directory
entry that makes it exist. Cost ~1.9 ms per commit — ~31% on single-document
commits, nothing measurable on batched writes (10k documents is one commit).

`GRANGE_FSYNC=0` opts out, and is only correct for rebuildable data (a mirror
that can be re-synced). Not guaranteed, at any setting: that the storage DEVICE
honours fsync.

## Memory: the watchdog, and the opt-in alternative

A long-lived actor retains memory per request. `GRANGE_MAX_RSS_MB` restarts the
process past the limit — safe (every commit is durable) but it drops in-flight
requests and parked watchers.

`GRANGE_RESET_EVERY=<n>` reclaims the arena between requests instead. It is
**off by default on purpose**: it lowers the sustained level a lot (measured
46→126 MB without, 23→61 MB with, over 6000 requests) but each reset is followed
by a reload of whatever the next request touches, so on a finely-sampled
multi-collection database the observed PEAK was worse (86 MB → 105 MB). Enable
it for long-running servers with modest collections; measure before trusting it.

It is disabled automatically when the token was randomly generated, because a
generated token cannot be re-derived after the arena is freed.

Also useful: `GRANGE_MAX_LOADED` evicts least-recently-used collections.

## Read replicas — the way to scale reads

`serve --follow` over the **same directory** is read-only and refreshes from
disk on every request. Route writes to the writer, reads to N followers.

Measured with an unindexed scan looping on one replica: another replica's get
p90 stayed at 0.4 ms and the primary's at 0.3 ms, where a single server took a
0.2 ms get to 85 ms.

Staleness is better than typical async replication and the mechanism is why: the
write is fsynced before it is acknowledged, and the follower re-reads on every
request, so a read issued after an acknowledged write sees it (30/30, no wait).
That holds for **same-directory** followers only — `grange follow` pulls a
remote primary into its own directory and is genuinely async.

Two things not to do: never point a replica at a COPY of the directory, and
never run two writers on one directory.

## Integrity

`grange verify --db d --coll c` walks every file — checksums, record structure,
manifest-vs-pages agreement, declared indexes — and exits 92 when anything is
wrong. Run it after moving a database between machines, and in any backup job:
it catches damage in files a query happens not to read.

## Publishing the SDKs

```sh
# PyPI — the token is at ~/.pypi (NOT ~/.pypirc; looking for the wrong filename
# is how this was twice reported as "needs the user" when it did not)
cd sdk/python && rm -rf dist && /usr/bin/python3 -m build && \
  TWINE_USERNAME=__token__ TWINE_PASSWORD="$(cat ~/.pypi)" /usr/bin/python3 -m twine upload dist/*

# npm — needs a human OTP, and the stored token expires (npm whoami returns E401)
cd sdk/node && npm publish --access public --otp=<code>
```

`/usr/bin/python3`, not `python3` — the latter has no pip modules on this box.

Registries are immutable: if the repo version already matches what is published,
BUMP rather than trying to republish. `make sdkversion` fails on exactly that.

## Liveness is not readiness

`/health` answers "up" as soon as the accept loop runs. It stays green while the
data directory has gone read-only, recovery quietly dropped chunks, RSS is about
to trip the watchdog, or the nightly backup stopped weeks ago. Those are the
failures that rot silently.

```sh
curl -s "$URL/ready" -H "authorization: Bearer $TOKEN"
```

`/ready` answers **503** when any of those is true, and lists what is failing. It
reads no pages and runs no verify, so it is cheap to poll. No backup marker at
all reports `null` rather than failing — plenty of deployments have no backup
job, and a false alarm teaches people to ignore the endpoint.

Point a monitor at `/health` for liveness and run `scripts/readycheck.sh` from a
timer for readiness. It alerts **only on transitions** and reports recovery,
because a message every 15 minutes while something is wrong gets muted, which is
worse than no alert. It also distinguishes `down` (no response) from `failing`
(responding, sick) — conflating them sends a misleading page.

On dk1: `grange-ready.timer` every 15 minutes, Telegram on transition.

## Backups

```sh
scripts/backup.sh --db /data/db --out /backups/grange --keep 7
```

Copy, verify, prune — in that order, and the order matters. A plain file copy is
a valid backup *while the database is being written*, because .grg files are
written once and never mutated, manifests are written last, and recovery drops a
torn final chunk: the copy can lose the in-flight commit and nothing else.
Measured under continuous writes: source 165 documents, restored 162, every one
whole.

What makes it a backup rather than a copy is `grange verify` on every collection.
A corrupt source exits **92** and the failed copy is KEPT for inspection;
pruning happens only after a good backup exists, so a run of failures never
empties the retention window.

**Tenant databases live in a sibling `<db>.tenants` directory.** A backup script
that copies only `--db` silently omits every paying customer. This one takes both
and lays them out as `<stamp>/<name>` and `<stamp>/<name>.tenants`, so restoring
is a copy back into place with no renaming.

Run it from a timer, not by hand — on dk1 it is `grange-backup.timer` at 03:30
UTC with `Persistent=true`. Until M45 the release notes claimed nightly backups
and there was no timer, no cron and no backup directory at all.

## Cold storage

`POST /cold?coll=C` converts a collection to disk-resident pages. Use it for
archival/analytics data: RSS stays flat where a hot collection holds everything
in memory (measured 4.4 MB vs 89.9 MB at 200k documents).

Large range-index builds spill sorted runs and merge them inside a scoped arena,
so declaring an index on a big cold collection no longer trips the watchdog
(measured 200k docs: +160 MB before, −11 MB after).

## Hosted, multi-tenant

A peage wallet is the signup credential: `POST /tenants` with
`X-Peage-Wallet: pw_...` returns a `gt_` token and an isolated namespace.
Storage is metered (`GRANGE_PRICE_CENTS_GB_MONTH`, `GRANGE_FREE_BYTES`), and
`GRANGE_RATE_PER_MIN` caps per-tenant requests — visible in `/usage`.

Set `GRANGE_MAX_SCAN_DOCS` on any shared deployment, or one tenant's scan
serialises everyone else.

**Do not burst-probe a live instance to measure it.** 200-request bursts trip
the fair-use cap; once the limiter engages the numbers are meaningless (one
probe reported a negative per-request cost). Reproduce the shape locally.
