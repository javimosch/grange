#!/usr/bin/env python3
"""Generate grange's `guide` and `help-json` into src/cli.src.

The guide is the interface documentation an agent reads, so a stale one MISLEADS
rather than merely omits: this file claimed "no fsync builtin yet — OS-crash
durability is best-effort" for ten milestones after fsync shipped, and listed 12
of the 19 verbs.

Keeping the content here rather than as hand-escaped JSON inside MFL string
literals is deliberate — 8 KB of escaped JSON edited by hand is how it rotted.
Edit the dicts below and re-run:

    python3 scripts/gen_guide.py && make build

scripts/guide_test.sh then checks that every verb, route and GRANGE_* variable
that exists in src/ actually appears here.
"""
import json
import re
import sys
from pathlib import Path

VERSION = "0.12.0"

GUIDE = {
    "tool": "grange",
    "version": VERSION,
    "model": (
        "document store: collections of minified-JSON docs keyed by id. A collection is HOT (whole "
        "dataset in memory, the memtable IS the database) or COLD (disk-resident, hash-partitioned "
        "pages + run manifests; convert with POST /cold). Writes stage in memory and become durable "
        "at commit: one immutable checksummed WAL chunk per commit, fsynced before the write is "
        "acknowledged. Recovery replays the newest valid segment + its valid chunks; a torn last "
        "chunk is dropped, so a commit is all-or-nothing."
    ),
    "loop": [
        "put --db d --doc '{...}' -> {id}",
        "get --db d --id X",
        "find --db d --where 'status=active,score>=10' --limit 50",
        "find --db d --order ts --desc --limit 5   (newest first; needs index --range on ts)",
        "find --db d --order ts --desc --after '<next cursor from the previous page>'",
        "count --db d --where status=active",
        "index --db d --field status --sums score   (equality + O(1) count/agg registers)",
        "index --db d --field ts --range            (sorted projection: ranges, ordering, cursors)",
        "agg --db d --group-by status --sum score",
        "compact --db d   (fold WAL chunks into a segment; run when stats.chunks_replayed grows)",
        "verify --db d --coll c   (walk every file; exit 92 if anything is wrong)",
        "serve --db d --port 8801 --token T   (HTTP; add --follow for a read-only replica)",
    ],
    "verbs": {
        "put": "--db --coll --id --doc [--ttl] -> {id}",
        "get": "--db --coll --id -> {id,doc}",
        "del": "--db --coll --id -> {id,deleted}",
        "find": "--db --coll [--where] [--limit] [--order F] [--desc] [--after CURSOR] [--fields a,b] -> {count,mode,scanned,pages,[next],items}",
        "count": "--db --coll [--where] -> {count,mode,scanned,pages}",
        "agg": "--db --coll --group-by F [--sum a,b] [--minmax a,b] -> {group_by,mode,groups}",
        "index": "--db --coll --field F [--sums a,b] [--range] -> {field,docs_indexed}",
        "indexes": "--db --coll -> declared indexes",
        "export": "--db --coll [--where] [--fields a,b] -> every matching document",
        "compact": "--db --coll -> {gen,docs}",
        "verify": "--db --coll -> {intact,issues}; exit 92 when not intact",
        "stats": "--db --coll -> {docs|docs_estimate,gen,runs,rss_kb,...}",
        "cold": "--db --coll -> convert the collection to disk-resident storage",
        "serve": "--db --port --token [--follow] -> HTTP server (single actor)",
        "follow": "--from URL --rtoken T --remote-db --remote-coll --db --coll [--once] -> pull a remote primary into a local db",
        "bench": "--db --n [--vs-sqlite]",
        "torture": "--db --n --batch [--cold] -> crash-test writer used by the crash harnesses",
        "guide": "this document",
        "help-json": "machine-readable command list",
    },
    "http": {
        "read": "GET /get /find /count /agg /export /stats /verify /collections /dbs /usage /watch /health /ready /guide",
        "write": "POST /put /del /bulk /index /cold /compact /tenants /shutdown",
        "auth": "Authorization: Bearer <token>. No anonymous access and no token query parameter.",
        "find_params": "coll, where, limit, order, desc=1, after=<cursor>, fields=a,b",
        "watch": "GET /watch?coll=&since=&timeout= long-polls for changes; resync=1 means you are too far behind to patch",
        "bulk": "POST /bulk?coll=C with one 'id<TAB>{json}' per line ('-<TAB>id' deletes); capped at 50000 ops, all-or-nothing",
    },
    "query": {
        "where": (
            "comma-separated clauses, ANDed: field=value, field~=substring, and numeric > < >= <= . "
            "Dotted paths reach nested fields (user.id=7). Values containing , or = are not "
            "expressible — get by id."
        ),
        "windows": "two clauses on one --range field (ts>=A,ts<B) fold into a single span: two binary searches, not a scan",
        "ordering": (
            "--order F [--desc] returns the first/last N BY F instead of an arbitrary N. Requires a "
            "--range index on F; asking without one is refused with the command to declare it. Ties "
            "break by id, so the order is TOTAL and the same query returns the same sequence on hot "
            "and cold."
        ),
        "pagination": (
            "keyset, not offset: an ordered response carries `next`, and --after/?after= resumes "
            "strictly past it. Every page costs the same, and rows inserted or deleted elsewhere "
            "cannot make a row repeat or be skipped. `next` is omitted on a short page, which is how "
            "you know to stop. A row MODIFIED between pages moves in the order and can be seen twice "
            "or missed — inherent without a snapshot."
        ),
        "projection": (
            "fields=a,b returns only those fields; `id` is ALWAYS included, a field the document "
            "lacks is OMITTED rather than null, and a dotted path projects under its full path "
            "(user.id) flat. Composes with ordering and cursors. Measured on 11-field documents, "
            "asking for 3 was 65% less payload — which for a caller paying per token is the point."
        ),
        "cost": "every response reports the plan (mode) and what it cost (scanned documents, pages read), so a caller can tell an index lookup from a scan",
        "still_scans": "a range clause on a field with no --range index; any ~= substring clause; multi-clause queries whose fields are unindexed",
    },
    "storage": {
        "hot": "memtable holds the whole collection; segments make open fast, not memory small",
        "cold": "hash-partitioned pages + per-run manifests written manifest-LAST, so an interrupted write leaves an unreferenced run rather than a corrupt one",
        "indexes": "equality (buckets / value-partitioned pages), --range (sorted projection / sorted pages + min-max boundaries), and O(1) count/agg registers via --sums",
        "index_builds": "large range-index builds spill sorted runs and k-way merge them inside a scoped arena, so a build is not bounded by the collection size",
    },
    "durability": (
        "a commit is fsynced before it is acknowledged: the chunk's content, then the directory entry "
        "that makes it exist. A cold flush fsyncs every page before the manifest naming it. Cost "
        "~1.9ms per commit, so ~31% on single-document commits and nothing measurable on batched "
        "writes. GRANGE_FSYNC=0 opts out for rebuildable data. NOT guaranteed: that the storage "
        "DEVICE honours fsync."
    ),
    "concurrency": (
        "`serve` is single-actor: one request at a time, so an expensive query is paid for by "
        "everyone behind it. Bound it with GRANGE_MAX_SCAN_DOCS, and scale reads with replicas — "
        "`serve --follow` over the SAME directory is read-only and refreshes from disk on every "
        "request. A read after an acknowledged write sees it (same-directory followers only; "
        "`follow` across machines is async)."
    ),
    "env": {
        "GRANGE_TOKEN": "serve: bearer token (else --token, else generated)",
        "GRANGE_DB": "serve: database directory when --db is absent",
        "GRANGE_FSYNC": "0 disables fsync on commit (faster, not crash-safe against power loss)",
        "GRANGE_MAX_SCAN_DOCS": "refuse a query after N documents examined; the error names the field to index",
        "GRANGE_MAX_SCAN_PAGES": "same, in pages read",
        "GRANGE_MAX_RSS_MB": "restart the process when RSS exceeds this (watchdog)",
        "GRANGE_RESET_EVERY": "reclaim the arena every N requests instead of restarting (opt-in; off by default)",
        "GRANGE_MAX_LOADED": "evict least-recently-used collections beyond this many",
        "GRANGE_MAX_RUNS": "compact a cold collection when it exceeds this many runs",
        "GRANGE_COLD_MEMTABLE": "flush a cold collection when the memtable reaches this many records",
        "GRANGE_BACKUP_MAX_HOURS": "/ready reports not-ready when the last recorded backup is older than this (default 48)",
        "GRANGE_RATE_PER_MIN": "per-tenant request cap (hosted)",
        "GRANGE_PRICE_CENTS_GB_MONTH": "hosted storage price",
        "GRANGE_MERCHANT_KEY": "peage merchant key for hosted billing",
        "GRANGE_FREE_BYTES": "hosted free storage allowance before metering",
        "GRANGE_SORT_SPILL": "records per spilled run during an external index build",
        "GRANGE_SORT_EXTERNAL": "1/0 forces the external or in-memory index build (testing)",
        "GRANGE_SORT_EXTERNAL_PAGES": "run size in pages above which a build spills",
        "GRANGE_BULK_DIRECT": "1 forces the direct-to-run bulk path (testing)",
        "GRANGE_BULK_PASS": "records held per pass when writing a bulk run",
        "GRANGE_IDX_PARTS": "partitions per cold equality index",
        "GRANGE_IDX_BATCH": "records per batch when building a cold index",
        "GRANGE_RANGE_PAGE": "entries per sorted range-index page",
    },
    "readiness": (
        "/health is liveness and stays trivial so a monitor can poll it often — it answers \"up\" as soon "
        "as the accept loop runs. /ready is the deep check and answers 503 when something is actually "
        "wrong: the data directory no longer writable, RSS within 10% of the watchdog limit (a restart "
        "drops in-flight requests and parked watchers), recovery having skipped chunks, or the nightly "
        "backup gone stale past GRANGE_BACKUP_MAX_HOURS (default 48; the backup script records a marker "
        "on success). No backup marker at all reports null rather than failing, because plenty of "
        "deployments have no backup job and a false alarm teaches people to ignore the endpoint. It reads "
        "no pages and runs no verify, so it is cheap enough to poll. An agent can use it to decide whether "
        "to trust a database it did not deploy."
    ),
    "backup": (
        "a plain file copy is a valid backup even while the database is being written: every .grg file "
        "is written once and never mutated, cold manifests are written LAST, and recovery drops a torn "
        "final chunk — so a copy can lose the in-flight commit and nothing else. What makes it a backup "
        "rather than a copy is verifying it: scripts/backup.sh copies, runs `verify` on every collection "
        "(exit 92 if anything is wrong), keeps a failed copy for inspection, and prunes only after a good "
        "one exists. Tenant databases live in a sibling <db>.tenants directory and are included — a "
        "backup that omits every paying tenant is worse than none. Restore is a copy back into place."
    ),
    "embed": (
        "grange is usable as a LIBRARY, not only a server: compile src/engine.src registry.src "
        "cold.src coldindex.src coldrange.src coldsort.src index.src range.src qcost.src query.src "
        "order.src into your own machin binary and call gr_use/gr_put/gr_commit/q_find/q_find_page "
        "directly. gr_reset() reclaims the arena and FREES everything the caller is holding, so call "
        "it between requests with nothing in flight. scripts/embed_test.sh pins this contract."
    ),
    "edge_cases": [
        "docs must be single-line minified JSON",
        "ids: no | / newline or slash",
        "a bulk request is capped at 50000 ops and is all-or-nothing: a malformed line applies nothing",
        "a replica (--follow) refuses writes; two writers on one directory would corrupt it",
        "gr_reset()/arena reset invalidates values the caller still holds, not just grange's internals",
    ],
    "exit_codes": {"0": "ok", "80-89": "input", "90-99": "not found", "92": "verify found corruption", "110-119": "internal"},
    "hosted": {
        "url": "https://grange.intrane.fr",
        "signup": "POST /tenants with X-Peage-Wallet: pw_... -> isolated metered namespace + gt_ token",
        "pricing": "pay-as-you-go storage, 15 cents/GB/month above 50MB free, billed via peage (https://peage.intrane.fr/llms.txt)",
    },
}

HELP = {
    "tool": "grange",
    "version": VERSION,
    "summary": "machin-native document database — agent-first, single binary, embeddable or served",
    "commands": [
        {"name": "put", "flags": ["--db", "--coll", "--id", "--doc", "--ttl"], "out": "{id}"},
        {"name": "get", "flags": ["--db", "--coll", "--id"], "out": "{id,doc}"},
        {"name": "del", "flags": ["--db", "--coll", "--id"], "out": "{id,deleted}"},
        {"name": "find", "flags": ["--db", "--coll", "--where", "--limit", "--order", "--desc", "--after", "--fields"], "out": "{count,mode,scanned,pages,next,items}"},
        {"name": "count", "flags": ["--db", "--coll", "--where"], "out": "{count,mode}"},
        {"name": "agg", "flags": ["--db", "--coll", "--group-by", "--sum", "--minmax"], "out": "{group_by,mode,groups}"},
        {"name": "index", "flags": ["--db", "--coll", "--field", "--sums", "--range"], "out": "{field,docs_indexed}"},
        {"name": "indexes", "flags": ["--db", "--coll"], "out": "{indexes}"},
        {"name": "export", "flags": ["--db", "--coll", "--where", "--fields"], "out": "{count,items}"},
        {"name": "compact", "flags": ["--db", "--coll"], "out": "{gen,docs}"},
        {"name": "verify", "flags": ["--db", "--coll"], "out": "{intact,issues}; exit 92 if not intact"},
        {"name": "stats", "flags": ["--db", "--coll"], "out": "{docs,gen,runs,rss_kb}"},
        {"name": "cold", "flags": ["--db", "--coll"], "out": "{cold:true}"},
        {"name": "serve", "flags": ["--db", "--port", "--token", "--follow"], "out": "HTTP server"},
        {"name": "follow", "flags": ["--from", "--rtoken", "--remote-db", "--remote-coll", "--db", "--coll", "--once"], "out": "replication into a local db"},
        {"name": "bench", "flags": ["--db", "--n", "--vs-sqlite"], "out": "benchmark metrics"},
        {"name": "torture", "flags": ["--db", "--n", "--batch", "--cold"], "out": "crash-test writer"},
        {"name": "guide", "flags": [], "out": "feature catalog"},
        {"name": "help-json", "flags": [], "out": "this command list"},
    ],
}


def mfl_chunks(s, size=150):
    """Split for MFL source lines WITHOUT ever cutting an escape sequence in half.

    Splitting between a backslash and its quote produced `...\\"` + `":[{...`,
    which is two unbalanced string literals and an unbalanced-braces parse error.
    """
    out, i = [], 0
    while i < len(s):
        j = min(i + size, len(s))
        k = j
        while k > i and s[k - 1] == "\\":
            k -= 1
        if (j - k) % 2 == 1:
            j -= 1
        out.append(s[i:j])
        i = j
    return out


def emit(fn, obj):
    s = json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
    s = s.replace("\\", "\\\\").replace('"', '\\"')
    parts = mfl_chunks(s)
    assert "".join(parts) == s, "chunker lost data"
    lines = ["func %s() {" % fn, '    s := ""']
    lines += ['    s = s + "%s"' % p for p in parts]
    lines += ["    println(s)", "}"]
    return "\n".join(lines)


def main():
    cli = Path(__file__).resolve().parent.parent / "src" / "cli.src"
    src = cli.read_text()
    # Idempotent: replace from the generated marker if it is already there.
    # Anchoring on "func cmd_guide" instead appended a SECOND grange_version on
    # the next run, because the marker block sits above it.
    marker = "// GENERATED by scripts/gen_guide.py"
    start = src.index(marker) if marker in src else src.index("func cmd_guide() {")
    end = src.index("func main() {")
    header = (
        "// GENERATED by scripts/gen_guide.py — edit the content there and re-run.\n"
        "// The guide is the interface documentation an agent reads, so a stale one\n"
        "// MISLEADS rather than merely omits: this claimed \"no fsync builtin yet\" for\n"
        "// ten milestones after fsync shipped. scripts/guide_test.sh fails when a verb,\n"
        "// route or GRANGE_* variable exists in src/ but not in the guide.\n"
        'func grange_version() (v) { v = "%s" }\n\n' % VERSION
    )
    body = header + emit("cmd_guide", GUIDE) + "\n\n" + emit("cmd_help_json", HELP) + "\n\n"
    cli.write_text(src[:start] + body + src[end:])
    print("wrote guide (%d bytes) and help-json (%d bytes) into %s"
          % (len(json.dumps(GUIDE)), len(json.dumps(HELP)), cli))


if __name__ == "__main__":
    main()
