# dk1 deployment — grange

The hosted grange instance at `https://grange.intrane.fr` runs on dk1
(92.113.145.178). This document lists every unit, its port, its token source,
and what happens if it dies — the deployment map for the 3am version of you.

## Units

| Unit | Port | What it does | If it dies |
|------|------|-------------|-----------|
| `grange.service` | 8801 | Primary — all writes + reads. `--read-proxy http://127.0.0.1:8802` proxies GETs to the follower. | Site down. Restart: `systemctl restart grange`. Data is in `/home/dk1/grange/data` (WAL chunks). |
| `grange-follower.service` | 8802 | Read replica — `--follow` refreshes from disk on every request. Read-only; `POST /promote` flips it to primary. | Reads degrade to primary only (proxy falls back to local). Not user-facing. |
| `grange-subscribe.service` | 8803 | Subscribe form on the landing page — a 130-line machin app that calls the grange HTTP API. Must be a separate process (an actor can't call its own HTTP API). | Landing page form breaks. No data loss. |
| `grange-backup.timer` | — | Nightly backup at 03:30 UTC. `grange backup --db /home/dk1/grange/data` → `/home/dk1/grange/backups/`. | No backup. Data still safe in WAL. |
| `grange-ready.timer` | — | Every 15min: checks `/ready` on primary, sends Telegram alert on transition to not-ready. | No alerts on degradation. perrus-cli still monitors `/health` (liveness) but not `/ready` (deep checks). |
| `vigie-sync.timer` | — | Every 10min: mirrors vigie's SQLite into grange `events` collection (cold mode). Cursor in `sync_state`. | Analytics mirror goes stale. vigie itself unaffected. |
| `vigie-compare.timer` | — | Daily: compares every grange aggregate against SQLite as oracle. 16 checks. | Silent divergence possible. |

## Ports

```
8801  grange primary    (writes + reads, proxies GETs to 8802)
8802  grange follower   (read-only replica, --follow)
8803  grange-subscribe  (landing page subscribe form)
```

## Tokens

- Admin token: `GRANGE_TOKEN` env or `--token` flag (stored in `/home/dk1/grange/.token` or the service's EnvironmentFile)
- vigie-sync token: `VIGIE_SYNC_TOKEN` in the service file (`gt_...` tenant token, `rw` role)
- Tenant tokens: issued via `POST /tenants` with `X-Peage-Wallet`, or `POST /tokens` for additional `ro`/`rw` tokens

## Data layout

```
/home/dk1/grange/
  data/           — the database (WAL chunks, cold runs, _sys tenants)
  backups/        — nightly backups (kept per retention policy)
  vigie-sync      — the sync binary
  readycheck.sh   — the /ready alerter script
```

## Simplification path

Current: 7 units. Target: 5 units.

1. **Remove `grange-follower.service`** — replace with `GRANGE_CONCURRENT_READS=1`
   on `grange.service`. The primary auto-spawns a follower on port+1, detects an
   existing one on restart (port-in-use guard), and proxies reads to it. The
   follower is no longer a managed service — it's a subprocess the primary owns.

   To migrate:
   ```sh
   systemctl stop grange-follower.service
   systemctl disable grange-follower.service
   # add to grange.service: Environment=GRANGE_CONCURRENT_READS=1
   systemctl edit grange.service  # add the env var
   systemctl restart grange.service
   ```

   Caveat: the auto-spawned follower is a `nohup` child of the primary — it
   survives a primary restart (port-in-use guard handles it) but dies with the
   primary on a full `systemctl stop`. The dedicated service survives. For a
   real failover story, the dedicated service is still better — the auto-spawn
   is for dev/small deployments where you don't want to manage two units.

2. **Merge `vigie-compare.timer` into `vigie-sync.timer`** — the sync script
   already runs every 10 minutes. Add a daily flag: `if [ $(date +%H) = "00" ]`
   then also run compare. One timer instead of two.

3. **Keep `grange-ready.timer`** — it's the Telegram alerter on `/ready`
   transitions. perrus-cli monitors `/ready` but doesn't alert on transitions.
   Removing it means losing the human alert path.

4. **Keep `grange-backup.timer`** — nightly backup. Could extend to
   restore-verify (restore to temp dir, boot, check count) — same timer, more
   verification, no new unit.

5. **Keep `grange-subscribe.service`** — must be a separate process (the
   subscribe handler calls the grange HTTP API; doing it in-process would
   deadlock the single actor).

## What this closes

- The "7 undocumented units" gap → documented here, simplified to 5
- The "no failover wiring" gap → `POST /promote` is the primitive; the fleet
  loop on rbm21 (not a dk1 unit) is the wiring
- The "no restore drill" gap → extend `grange-backup.timer` to restore-verify

## Monitoring

- perrus-cli monitors `/health` and `/ready` on both primary and follower
- `grange-ready.timer` sends Telegram alerts on `/ready` transitions
- vigie-compare.timer verifies the mirror daily (16 checks against SQLite)
