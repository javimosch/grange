# Deploying grange — a generic guide

How to run grange in production. No specific infrastructure — just the
patterns that work.

## The minimal deployment

```sh
grange serve --db /data --port 8801 --token "$(openssl rand -hex 32)"
```

One process, one port, one token. That's a working grange.

## Optional: read replica

For read-heavy workloads, add a follower:

```sh
grange serve --db /data --port 8802 --token "$TOKEN" --follow
```

Then point the primary at it:

```sh
grange serve --db /data --port 8801 --token "$TOKEN" --read-proxy http://127.0.0.1:8802
```

Or let the primary auto-spawn one:

```sh
GRANGE_CONCURRENT_READS=1 grange serve --db /data --port 8801 --token "$TOKEN"
```

The auto-spawned follower is a subprocess of the primary (survives restart,
detects existing follower on port+1). For a dedicated service you can
independently restart, use a separate unit instead.

## Optional: failover

A follower is read-only until promoted:

```sh
curl -X POST http://127.0.0.1:8802/promote -H "Authorization: Bearer $TOKEN"
```

The follower flips to primary in one request — the data is already local.
A watchdog script (systemd timer, cron, or a fleet loop on another host)
should call this when the primary's `/ready` fails twice in a row.

## Optional: backup

```sh
./scripts/backup.sh --db /data --out /backups/grange --keep 7
```

Copies the database, verifies every collection's checksums, prunes old
backups. Run it from a timer. A backup nobody verified is a hope.

## Optional: readiness monitoring

`GET /ready` (admin token) reports:

- RSS vs the watchdog limit
- Backup age (if a `.last_backup` marker exists)
- Disk space vs `GRANGE_DISK_MIN_BYTES`
- Recovery state (skipped chunks, WAL integrity)

Poll it from your monitoring. The endpoint is cheap — reads no pages, runs
no verify.

## Optional: memory bounding

```sh
GRANGE_MAX_RSS_MB=300 grange serve ...
```

The watchdog restarts the process when RSS exceeds the limit. Gentler:

```sh
GRANGE_RESET_EVERY=200 grange serve ...
```

Reclaims the arena every N requests instead of restarting. `GET /memory`
reports the full picture.

## Optional: RBAC

```sh
curl -X POST http://127.0.0.1:8801/tokens \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"tenant":"t_...","role":"ro"}'
```

Issues a read-only token for a tenant. Existing tokens default to `rw`.

## What NOT to add

- **A separate follower service when `GRANGE_CONCURRENT_READS=1` covers it**
  — the auto-spawn is simpler for dev/small deployments
- **A dedicated readiness timer when your monitor already polls `/ready`**
  — only add a separate alerter if you need transition alerts (e.g., Telegram)
- **A backup timer when you have no restore drill** — a backup you can't
  restore is worse than no backup (it gives false confidence)

## The 3am checklist

When grange is down:

1. `systemctl status grange` — is it running?
2. `journalctl -u grange -n 50` — what's the last log line?
3. `curl http://127.0.0.1:8801/health` — is it up but not ready?
4. `curl http://127.0.0.1:8801/ready -H "Authorization: Bearer $TOKEN"` — deep check
5. `curl http://127.0.0.1:8801/memory -H "Authorization: Bearer $TOKEN"` — RSS, resets, loaded collections
6. Check disk space — `df -h /data`
7. Check the last backup — `cat /data/.last_backup`
