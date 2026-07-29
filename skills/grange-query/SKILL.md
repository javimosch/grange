---
name: grange-query
description: Query grange effectively — filters, time windows, ordering, keyset pagination, reading the cost fields, and knowing which shapes still scan. Use when reading or writing code that queries a grange collection over CLI, HTTP or an SDK.
---

# Querying grange

Start with `grange guide` — it is version-exact for the binary in front of you.
This skill is the part that is easy to get wrong.

## Read the cost fields; they are the point

Every response reports the plan and what it cost:

```json
{"count":2,"mode":"cold-index-multi","scanned":0,"pages":30,"items":[...]}
```

- `mode` — the plan: `indexed`, `range`, `range-ordered`, `scan`, `cold-index`,
  `cold-index-multi`, `cold-range-ordered`, `cold-scan`
- `scanned` — documents examined; `pages` — pages read from disk

A `mode` beginning `scan` on a collection of any size means a missing index, not
a slow database. Measured on 200k documents: an indexed lookup reported 2 pages
/ 0 documents where the equivalent scan reported 256 pages / 50,000.

## Filters

`--where` / `?where=` is comma-separated clauses, ANDed:

```
status=active,score>=10,name~=smith,user.id=7
```

Equality, numeric `> < >= <=`, `~=` substring, and dotted paths into nested
documents. A value containing `,` or `=` is not expressible — fetch by id.

## Time windows are one span, not two scans

Two clauses on the same `--range` field fold into a single span:

```
--where 'ts>=1785000000,ts<1785002000'
```

Hot: two binary searches. Cold: the range index. Either way it does not scan.

## "The latest N" needs an order, and an order needs a range index

A limit **without** an order returns an arbitrary subset — it used to hand back
the *earliest* rows for a query meant to show the newest.

```sh
grange index --db d --coll events --field ts --range      # declare once
grange find  --db d --coll events --order ts --desc --limit 5
```

Asking to order on a field with no range index is refused, and the error names
the command that fixes it. Ties break by id, so the order is **total**: the same
query returns the same sequence on hot and cold storage.

## Pagination is keyset, never offset

An ordered response carries `next`. Pass it back as `--after` / `?after=`:

```sh
grange find --db d --coll events --order ts --desc --limit 50
# -> {"next":"1785223773|e728", ...}
grange find --db d --coll events --order ts --desc --limit 50 --after '1785223773|e728'
```

`next` is omitted on a short page — that is how you know to stop. Every page
costs the same, and a cursor names a position in the ORDER, so rows inserted or
deleted elsewhere cannot make a row repeat or be skipped.

The honest limit: a row **modified** between pages moves in the order and can be
seen twice or missed. That is inherent to reading a changing collection without
a snapshot.

## What still scans

- a range clause on a field with no `--range` index
- any `~=` substring clause
- multi-clause queries whose fields are all unindexed

## Budgets, on a shared server

`grange serve` handles one request at a time, so an expensive query is paid for
by everyone behind it. `GRANGE_MAX_SCAN_DOCS` refuses a query past a budget with
an error naming the field to index. Set it on anything multi-tenant: measured, a
0.2 ms get became 85 ms while one unindexed scan ran, and 3 ms with a budget.

To scale reads instead of refusing them, see `grange-operate` (replicas).
