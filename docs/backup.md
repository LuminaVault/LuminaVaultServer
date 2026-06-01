# Backup & Restore Runbook (HER-131)

Automated daily, age-encrypted, off-site backups for self-hosted
LuminaVaultServer. This covers one-time setup, day-to-day operation, the restore
procedure, and the quarterly drill. For host provisioning see
[`hetzner-deployment.md`](./hetzner-deployment.md); for deploy/rollback see
[`deploy.md`](./deploy.md).

## What gets backed up

| Asset | How | Artifact |
|-------|-----|----------|
| Postgres (`hermes_db`) | `pg_dump --format=custom` over the network | `pg.dump.age` |
| Vault files (`data/luminavault/`) | `tar` of the bind mount | `luminavault.tar.age` |
| Hermes skills + memory (`data/hermes/`) | `tar` of the bind mount | `hermes.tar.age` |

Each nightly run writes a snapshot dir `remote/daily/<YYYY-MM-DD>/` containing
the three `*.age` artifacts plus `MANIFEST.txt` (sizes + sha256, used to verify
integrity before restore).

> **Note:** Postgres is dumped logically (`pg_dump`), **not** by copying
> `data/postgres18/`. Never back up a live Postgres data dir by file copy — the
> result is torn and may not restore.

## Architecture & threat model

- **Encrypt-only sidecar.** The `backup` container holds the age **recipient
  public key** only (`age -r`). It cannot decrypt anything it writes. The
  matching **private identity** lives in `./secrets/` and is read only by
  `restore.sh` / the CI drill. A compromised backup container leaks nothing.
- **Generic remote.** Backups go to any rclone remote — Backblaze B2, AWS S3,
  MinIO, or a Hetzner Storage Box (rclone SFTP). Configure it once in
  `./secrets/rclone.conf`.
- **Tiered retention.** Daily snapshots are promoted to `weekly/` (on
  `BACKUP_WEEKLY_DOW`, default Sunday) and `monthly/` (on the 1st). Each tier is
  pruned to its retain count: **7 daily / 4 weekly / 6 monthly** by default.
- **Opt-in.** The service sits behind a compose `profiles: ["backup"]` guard, so
  it does nothing until you configure keys and bring it up explicitly.

## One-time setup

All paths are relative to the deploy dir on the VPS (`/opt/obsidian-claudebrain`).

### 1. Generate an age keypair

```bash
mkdir -p secrets
age-keygen -o secrets/age-identity.txt
# Prints "Public key: age1...." — that's your recipient.
chmod 600 secrets/age-identity.txt
```

- The **private** `secrets/age-identity.txt` is needed only for restore. Back it
  up somewhere offline (password manager). **If you lose it, your backups are
  unrecoverable — that is the point of encryption.**
- The mount `./secrets:/app/secrets:ro` already exists for the app, so the
  identity is reachable at `/app/secrets/age-identity.txt` (the default
  `BACKUP_AGE_IDENTITY_PATH`).

### 2. Configure the rclone remote

```bash
docker run --rm -it -v "$PWD/secrets:/config/rclone" rclone/rclone config
# create a remote, e.g. name it "b2" (Backblaze) or "s3" (AWS/MinIO).
# This writes ./secrets/rclone.conf, which the backup service mounts read-only.
```

### 3. Set env in `.env.production`

```dotenv
BACKUP_AGE_RECIPIENT=age1....................................   # public key from step 1
BACKUP_RCLONE_REMOTE=b2:my-bucket/luminavault                  # remote:bucket/path
BACKUP_AGE_IDENTITY_PATH=/app/secrets/age-identity.txt         # restore-only
# optional overrides (defaults shown):
# BACKUP_CRON=0 3 * * *
# BACKUP_RETAIN_DAILY=7
# BACKUP_RETAIN_WEEKLY=4
# BACKUP_RETAIN_MONTHLY=6
# BACKUP_WEEKLY_DOW=7
```

See `.env.example` for the full annotated block.

### 4. Enable the backup service

```bash
make backup-image     # build luminavault-backup:local once
docker compose -p prod -f docker-compose.production.yml \
  --profile backup --env-file .env.production up -d backup
docker compose -p prod logs -f backup   # watch the schedule register
```

Verify the first run on demand: `make backup-now` (or set
`BACKUP_RUN_ON_START=true` for one immediate run on container start).

## Verifying backups

```bash
# list snapshots
docker compose -p prod -f docker-compose.production.yml --profile backup \
  run --rm backup rclone lsf "$BACKUP_RCLONE_REMOTE/daily/"

# inspect a manifest
docker compose -p prod -f docker-compose.production.yml --profile backup \
  run --rm backup rclone cat "$BACKUP_RCLONE_REMOTE/daily/<date>/MANIFEST.txt"
```

## Restore procedure (disaster recovery)

`restore.sh` is **destructive**: `pg_restore --clean` drops and recreates DB
objects, and vault/hermes tars extract over the live bind mounts. Order matters.

1. **Stop the app** (so nothing writes mid-restore):
   ```bash
   docker compose -p prod -f docker-compose.production.yml stop app hermes
   ```
   Keep `postgres` running (restore connects to it).

2. **Run the restore** for the chosen date:
   ```bash
   make backup-restore DATE=2026-06-01                 # all components
   # or a single component:
   make backup-restore DATE=2026-06-01 COMPONENT=pg
   ```
   `make backup-restore` passes `--force`. To review first, run the script
   interactively instead and answer the confirmation prompt:
   ```bash
   docker compose -p prod -f docker-compose.production.yml --profile backup \
     run --rm backup /usr/local/bin/restore.sh 2026-06-01
   ```
   It auto-selects the tier (daily → weekly → monthly) and verifies sha256
   against the MANIFEST before decrypting. Override with `--tier weekly`.

3. **Restart + verify**:
   ```bash
   docker compose -p prod -f docker-compose.production.yml \
     --env-file .env.production up -d app hermes
   curl -fsS http://127.0.0.1:8080/health
   # then exercise an authed route, e.g. GET /v1/me with a saved token.
   ```

## Quarterly restore drill

The drill proves the scripts actually round-trip — a backup you have never
restored is a hope, not a backup.

- **CI:** `.github/workflows/restore-drill.yml` runs on the 1st of Jan/Apr/Jul/Oct
  (and on demand via **Actions → Restore Drill → Run workflow**). It uses an
  ephemeral age key and rclone's local backend, so no real credentials are
  touched. A failing run means restore is broken.
- **Locally:** `make backup-drill` runs the same `scripts/backup-drill.sh`
  against your dev Postgres.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Service won't start: `set BACKUP_AGE_RECIPIENT...` | env not set in `.env.production` |
| `rclone: directory not found` on first prune | normal — tiers are created on first write |
| Restore: `checksum mismatch` | corrupt/partial upload; restore an earlier snapshot |
| Restore: `age: no identity matched` | wrong `BACKUP_AGE_IDENTITY_PATH` / lost private key |
| pg_restore warnings about existing objects | benign with `--clean --if-exists` |

## Files

- `scripts/backup.sh` — nightly job (pg + vault + hermes → encrypt → upload → prune).
- `scripts/restore.sh` — restore `<date> [--component] [--tier] [--force]`.
- `scripts/backup-lib.sh` — shared logging / env / retention helpers.
- `scripts/backup-drill.sh` — round-trip drill (CI + `make backup-drill`).
- `docker/backup.Dockerfile`, `docker/backup-entrypoint.sh`, `docker/run-backup.sh` — the sidecar image.
- `docker-compose.production.yml` — the `backup` service (profile `backup`).
