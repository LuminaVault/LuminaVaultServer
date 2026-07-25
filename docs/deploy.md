# Deploy & Rollback Runbook

Production CI/CD for `LuminaVaultServer`. This is the operational runbook: how a
release reaches the cluster, how to promote to production, how to roll back, and
where to look when it breaks.

Deployment is **GitOps on k3s**. The old SSH-to-VPS pipeline (`prod.yml` /
`dev.yml`) was retired (#171); the cluster is now the source of truth and
[`LuminaVaultInfra`](https://github.com/LuminaVault/LuminaVaultInfra) holds the
manifests ArgoCD reconciles. For host/cluster provisioning see
[`hetzner-deployment.md`](./hetzner-deployment.md); for backups + restore see
[`backup.md`](./backup.md); for branch protection see
[`cicd/branch-protection.md`](./cicd/branch-protection.md).

## Pipeline overview

```
PR ──► CI (lint + test)  ──merge──►  push to main
                                         │
                                         ▼
                              CI runs again on main
                                         │  on success (workflow_run)
                                         ▼
                        Release workflow (.github/workflows/release.yml)
              build ──► push ghcr.io/luminavault/luminavaultserver:<sha>
                                         │
                                         ▼
                 bump-staging: commit image.tag=<sha> into
                 LuminaVaultInfra apps/api/values-staging.yaml
                                         │
                                         ▼
                 ArgoCD auto-syncs the `staging` namespace (~3 min, hands-free)
                                         │
                                         ▼   ── manual gate ──
                 Promote to Production (LuminaVaultInfra promote.yml, dispatch)
                 copies staging tag → values-production.yaml, opens a PR
                                         │  merge the PR = approval
                                         ▼
                 ArgoCD auto-syncs the `production` namespace → prod live
```

Key properties:

- **CI gates the build.** `release.yml` triggers via `workflow_run` on the `CI`
  workflow completing **successfully** on `main`. A failing `lint` or `test`
  job means CI fails, so no image is built and staging is never bumped.
- **Image is immutable.** Built once from the exact CI-validated commit, tagged
  with the git SHA (`ghcr.io/luminavault/luminavaultserver:<sha>`), and the
  *same* image is what staging runs and what gets promoted to production. No
  rebuild between environments.
- **Staging is automatic; production is human-gated.** Every green merge lands
  in staging within ~3 min with no human action. Production only changes when
  someone runs `promote.yml` and **merges** the resulting promote PR.
- **ArgoCD is the deployer.** The `api-staging` / `api-production` Applications
  (namespaces `staging` / `production`) track `LuminaVaultInfra@main` with
  `automated` sync + `prune` + `selfHeal`. Merging a tag change is the deploy;
  hand-editing cluster objects is reverted by selfHeal — the git tag wins.
- **Migrations run at boot, fail-fast.** The app runs migrations on startup
  (`fluent.autoMigrate`, on outside `dev`); a migration error crashes the pod
  and ArgoCD/k8s keep the previous ReplicaSet serving. Migrations must stay
  compatible with the last-known-good image — an **application** rollback does
  **not** revert database schema (see Rollback).
- **Health probe:** `https://api.luminavault.fyi/health` returns `ok` (public
  liveness). Do **not** use `/v1/health` — that is the JWT-authed health-data
  domain and returns 401.

## How a change reaches staging (automatic)

1. Merge a PR to `main`. CI re-runs on `main`.
2. On CI success, **Release** (`release.yml`) builds + pushes
   `…/luminavaultserver:<sha>`, then its `bump-staging` job checks out
   `LuminaVaultInfra` (using the `INFRA_REPO_TOKEN` PAT), sets
   `apps/api/values-staging.yaml → image.tag: <sha>`, and pushes to infra
   `main`. A Discord line reports the result.
3. ArgoCD reconciles `api-staging` and rolls the `staging` namespace to the new
   image (~3 min). Verify against the staging host (see `hetzner-deployment.md`
   for the staging URL).

## How to promote to production (manual gate)

1. GitHub → **LuminaVaultInfra** → Actions → **Promote to Production** → **Run
   workflow** → `service: api`.
2. That opens a `promote/<timestamp>` PR that copies the current
   `values-staging.yaml` tag into `values-production.yaml`.
3. Review (confirm the tag is the SHA you validated in staging) and **merge**.
   Merging is the approval.
4. ArgoCD reconciles `api-production` and rolls the `production` namespace. Watch
   the ArgoCD UI (or `argocd app get api-production`) until `Synced` + `Healthy`,
   then smoke `https://api.luminavault.fyi/health` → `ok`.

## Rollback

The git tag in `LuminaVaultInfra` is the source of truth, so rollback = point it
back at a known-good SHA and let ArgoCD converge. selfHeal means you must change
**git**, not the cluster.

- **Revert the promote PR** (preferred). In `LuminaVaultInfra`, revert the merge
  that bumped `values-production.yaml`; ArgoCD syncs production back to the
  previous tag. `promote.yml`'s PR body notes this ("Rollback: revert this PR").
- **Pin an explicit tag.** Open a one-line PR setting
  `apps/api/values-production.yaml → image.tag: "<known-good-sha>"` and merge.
  Any GHCR `:<sha>` that was previously live is a valid target.
- **Staging rollback:** revert the `bump-staging` commit on infra `main`, or pin
  the staging tag the same way.

Schema rollback is **not** automatic. Additive migrations are safe under an
application rollback (the previous image runs against the newer schema). Any
destructive or semantically-breaking migration must ship as a staged
expand/migrate/contract release, never a single-release cutover.

## Force a re-sync / redeploy without a new commit

ArgoCD auto-syncs, so this is rarely needed. To force reconciliation (e.g. after
a manual secret rotation) use the ArgoCD UI **Sync**, or:

```bash
argocd app sync api-production      # or api-staging
argocd app get api-production       # confirm Synced + Healthy
```

To rebuild + re-push the image for the current `main` without a new merge, run
**Release** (`release.yml`) via `workflow_dispatch`; it re-bumps staging.

## Secrets & configuration

- **Application env (~140 vars: Postgres, `JWT_HMAC_SECRET`,
  `LV_SECRET_MASTER_KEY`, `HERMES_API_KEY`, OAuth, APNS, Sentry, LLM keys,
  `PLUGIN_RUNNER_TOKEN`, `PLUGIN_ARTIFACT_SIGNING_KEY`, …)** live in the sealed
  `api-env` Secret in each namespace, managed in `LuminaVaultInfra` — **not** in
  this repo and no longer in a VPS `.env.production`. To change one, update the
  sealed secret in the infra repo (see its README / `argocd/apps/secrets.yaml`).
- **This repo's GitHub secrets** are only what `release.yml` needs:

  | Name | Used by | Purpose |
  |------|---------|---------|
  | `INFRA_REPO_TOKEN` | `release.yml` bump-staging | Fine-grained PAT (contents: read/write) on `LuminaVault/LuminaVaultInfra` so CI can commit the staging tag |
  | `DISCORD_WEBHOOK_URL` | `release.yml` notify (optional) | Release notifications |
  | `GITHUB_TOKEN` | `release.yml` build | GHCR push (automatic) |

## Observability & on-call

- **Health:** `https://api.luminavault.fyi/health` (public, returns `ok`).
- **Sentry:** errors/traces for env `production`; releases tagged with the
  deploy commit SHA. Wiring lives with the cluster config in `LuminaVaultInfra`.
- **Cluster:** inspect via ArgoCD (app health/sync) and `kubectl -n production`
  (pods, logs, events). See `hetzner-deployment.md` for cluster access.
- **On-call:** Fernando Correia (<fernandocorreia316@gmail.com>). Update this
  line when a rotation is established.
