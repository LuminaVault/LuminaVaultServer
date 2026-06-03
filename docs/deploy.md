# Deploy & Rollback Runbook (HER-272)

Production CI/CD for `LuminaVaultServer`. This is the operational runbook:
how a release reaches the VPS, how to roll back, and where to look when
it breaks. For host provisioning, TLS/Caddy, and networking see
[`hetzner-deployment.md`](./hetzner-deployment.md); for encrypted off-site
backups and the restore procedure see [`backup.md`](./backup.md). For branch
protection see [`cicd/branch-protection.md`](./cicd/branch-protection.md).

## Pipeline overview

```
PR ──► CI (lint + test)  ──merge──►  push to main
                                         │
                                         ▼
                              CI runs again on main
                                         │  on success (workflow_run)
                                         ▼
                        Deploy workflow (.github/workflows/prod.yml)
              build ──► push ghcr.io/luminavault/luminavaultserver:<sha> + :latest
                                         │
                                         ▼
                 SSH to VPS: pull image, write .env.production, compose up app
                                         │
                                         ▼
                 on-server health pre-gate (http://127.0.0.1:8080/health)
                                         │
                                         ▼
            runner smoke test (https://api.luminavault.fyi/health → 200, ≤30s)
                                   │              │
                              success           failure
                                   ▼              ▼
                         Promote release    Roll back to .green_image
                         (.green_image,      (redeploy last good,
                          prune images)       job stays red)
```

Key properties:

- **CI gates deploy.** `prod.yml` triggers via `workflow_run` on the `CI`
  workflow completing **successfully** on `main`. A failing `lint` or
  `test` job means CI fails, so the deploy never starts.
- **Image is immutable.** Built once in CI, tagged with the commit SHA,
  pulled (not rebuilt) on the VPS.
- **Smoke test is authoritative and runs from the GitHub runner** against
  the public HTTPS endpoint. It hits **`/health`** (public liveness probe,
  returns `"ok"`) — **not** `/v1/health`, which is the JWT-authed
  health-data domain and returns 401.

> **GitHub caveat:** `workflow_run` always uses the workflow definition
> from the **default branch**. Changes to `prod.yml`/`dev.yml`/`ci.yml`
> only take effect for gating once they are on `main`. You cannot fully
> exercise the gate from a feature branch.

## Most-recent-green pointer

The VPS keeps two small files in `/opt/obsidian-claudebrain`:

- **`.green_image`** — the last image that passed its smoke test. Written
  by the **Promote release** step. This is the rollback target.
- **`.rollback_image`** — written at the *start* of each deploy as a copy
  of `.green_image` (or the currently-live `APP_IMAGE` if no green pointer
  exists yet). The **Roll back on failure** step redeploys this.

`APP_IMAGE` in `.env.production` always reflects the *currently deployed*
image (good or bad); `.green_image` reflects the last *known-good* image.

## Automatic rollback

If the deploy step errors or the smoke test does not return `200` within
~30s, the `if: failure()` **Roll back on failure** step runs:

1. Reads `.rollback_image`.
2. `docker pull` that image, rewrites `APP_IMAGE=` in `.env.production`.
3. `docker compose -p prod -f docker-compose.production.yml up -d --no-deps app`.

The workflow run stays **red** so the failure is visible, even though the
service has been restored to the last good image.

## Manual rollback

SSH to the VPS and redeploy a known-good image. This is the
`docker compose rollback` equivalent.

```bash
ssh <SERVER_USER>@<SERVER_HOST>
cd /opt/obsidian-claudebrain

# 1. Pick a target image. Last known-good:
cat .green_image
# ...or list recent SHA tags in GHCR and choose one:
#   ghcr.io/luminavault/luminavaultserver:<short-sha>

TARGET="ghcr.io/luminavault/luminavaultserver:<sha>"

# 2. Pull + redeploy.
echo "$GHCR_TOKEN" | docker login ghcr.io -u <user> --password-stdin
docker pull "$TARGET"
sed -i "s|^APP_IMAGE=.*|APP_IMAGE=${TARGET}|" .env.production
APP_PORT=8080 APP_IMAGE="$TARGET" docker compose -p prod \
  -f docker-compose.production.yml \
  --env-file .env.production \
  up -d --no-deps app

# 3. Verify.
curl -fsS http://127.0.0.1:8080/health        # on-server
curl -fsS https://api.luminavault.fyi/health   # public

# 4. (optional) Re-point :latest to the rolled-back image so a plain
#    `docker compose pull` elsewhere converges on the good image.
docker tag "$TARGET" ghcr.io/luminavault/luminavaultserver:latest
docker push ghcr.io/luminavault/luminavaultserver:latest

# 5. Record it as the new green so future auto-rollbacks target it.
echo "$TARGET" > .green_image
```

## Manual redeploy / re-run

- Re-run the last deploy without a new commit: GitHub → Actions → **Deploy**
  → **Run workflow** (`workflow_dispatch`).
- `workflow_dispatch` skips the CI gate (use only for redeploy/rollback).

## Observability & on-call

- **Health:** `https://api.luminavault.fyi/health` (public, returns `ok`).
- **Sentry:** errors/traces for env `production`. Project/org are set via
  the `SENTRY_ORG_SLUG` / `SENTRY_PROJECT_SLUG` GitHub secrets; releases
  are tagged with the deploy commit SHA (`SENTRY_RELEASE`).
- **Jaeger** (traces) runs on the VPS bound to localhost only — reach the
  UI over an SSH tunnel:
  ```bash
  ssh -L 16686:127.0.0.1:16686 <SERVER_USER>@<SERVER_HOST>
  # then open http://127.0.0.1:16686
  ```
- **PostHog:** logs are fanned out by the `otel-collector` container
  (`POSTHOG_OTEL_TOKEN`).
- **On-call:** Fernando Correia (<fernandocorreia316@gmail.com>). Update
  this line when on-call rotation is established.

## Required GitHub secrets / vars

| Name | Used by | Purpose |
|------|---------|---------|
| `SERVER_HOST`, `SERVER_USER`, `SERVER_SSH_KEY` | deploy/rollback | SSH to VPS |
| `POSTHOG_OTEL_TOKEN` | deploy | otel-collector log export |
| `SENTRY_*` | deploy | Sentry release + env wiring |
| `SLACK_WEBHOOK_URL` | notify (optional) | deploy notifications (deferred) |
| `vars.PRODUCTION_HEALTH_URL` (optional) | smoke test | override the smoke URL (default `https://api.luminavault.fyi/health`) |
| `BACKUP_AGE_RECIPIENT` (optional) | deploy | HER-131 backup encryption recipient (age public key) |
| `BACKUP_RCLONE_REMOTE` (optional) | deploy | HER-131 backup destination, e.g. `b2:bucket/luminavault` |
| `BACKUP_ALERT_WEBHOOK` (optional) | deploy | HER-131 Slack webhook for backup-failure alerts |

## Backups (HER-131)

The deploy writes the `BACKUP_*` secrets into `.env.production` and, when both
`BACKUP_AGE_RECIPIENT` and `BACKUP_RCLONE_REMOTE` are present **and**
`./secrets/rclone.conf` exists on the host, brings up the `backup` profile
sidecar. A backup-service start failure is logged but does **not** fail the
deploy.

One-time host setup is still manual (the deploy never invents keys):

```bash
ssh <SERVER_USER>@<SERVER_HOST>
cd /opt/obsidian-claudebrain

# 1. age keypair — keep the private identity safe & offline.
age-keygen -o secrets/age-identity.txt && chmod 600 secrets/age-identity.txt
#    note the "Public key: age1..." line → set BACKUP_AGE_RECIPIENT (GH secret
#    or directly in .env.production).

# 2. rclone remote (Backblaze B2 / AWS S3 / MinIO / SFTP).
docker run --rm -it -v "$PWD/secrets:/config/rclone" rclone/rclone config

# 3. set the remote + recipient (GH secrets, or .env.production directly):
#    BACKUP_AGE_RECIPIENT=age1....
#    BACKUP_RCLONE_REMOTE=b2:my-bucket/luminavault
#    BACKUP_AGE_IDENTITY_PATH=/app/secrets/age-identity.txt
```

Next deploy auto-starts the sidecar. Full operator runbook (retention, restore,
drill, alerting): [`backup.md`](./backup.md).
