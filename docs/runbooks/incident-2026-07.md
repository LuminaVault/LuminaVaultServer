# Incident 2026-07 — xmrig on Hermes VPS + full credential rotation

**Status:** OPEN — work the checklists top to bottom; check items off in this file via PRs (or edits on main) so the state is auditable.

## What happened

On 2026-07-04, an active `xmrig` cryptominer was found running on the Hermes VPS
`78.46.192.73` during unrelated work. Entry vector unconfirmed. The production
API VPS `167.233.30.48` shares operator SSH keys and tooling history with that
box and is treated as **suspect** until it is replaced (deployment
modernization plan, Phase 4). Consequences:

1. Every credential that ever lived on either box, or that the operator used
   from them, gets rotated (checklist below).
2. Both boxes get rebuilt from code — the compromised one immediately, the
   prod one at the Phase 4 cutover. Nothing is copied off either box except
   Postgres data via the encrypted backup path (`pg_dump | age | rclone`).

## A. Containment — 78.46.192.73 (compromised)

- [ ] A1. Hetzner console: snapshot the server (forensics record) — label `incident-2026-07-xmrig`.
- [ ] A2. Power off the server.
- [ ] A3. Remove its SSH host keys / entries from `~/.ssh/known_hosts` and any config referencing it.
- [ ] A4. Audit the Hetzner project: unknown servers, volumes, snapshots, firewall rule changes, added SSH keys, API tokens list + last-used timestamps.
- [ ] A5. Destroy the server (after A1 snapshot confirms).

## B. Credential rotation

Rotate in this order. For each: issue new → deploy new → verify service healthy → revoke old. Do not batch revocations before verification.

| # | Done | Credential | Where used | Notes |
|---|------|-----------|------------|-------|
| 1 | [ ] | Hetzner Cloud API token | local CLI / any tooling | New token only to HCP Terraform + local keychain |
| 2 | [ ] | SSH keypair(s) for both VPSes | GH secret `SERVER_SSH_KEY`, `authorized_keys` | New keypair; remove old pubkeys from prod box now |
| 3 | [ ] | GitHub org audit | github.com/LuminaVault | Members, deploy keys, OAuth app grants, Actions secrets inventory, 2FA enforcement |
| 4 | [ ] | Postgres password | VPS `.env.production` | Maintenance window; app restart required |
| 5 | [ ] | `JWT_HMAC_SECRET` | `.env.production` | Invalidates all sessions — users re-login |
| 6 | [ ] | `LV_SECRET_MASTER_KEY` (SecretBox) | `.env.production` | CAUTION: re-encrypt stored BYOK/gateway secrets — needs a migration/re-wrap script, do NOT rotate blind |
| 7 | [ ] | `HERMES_API_KEY` | `.env.production` + hermes config | |
| 8 | [ ] | `ADMIN_TOKEN` | GH secret + `.env.production` | |
| 9 | [ ] | LLM provider keys (OpenRouter, Gemini, others in `.env.production`) | server env | Rotate at each provider console |
| 10 | [ ] | Google Calendar OAuth client secret (`OAUTH_GOOGLECALENDAR_CLIENTSECRET`) | server env + GCP console | |
| 11 | [ ] | APNS `.p8` key | `secrets/` on VPS + Apple Developer | Revoke old key in Apple Dev portal; new key → GH secret + secrets/ |
| 12 | [ ] | Sentry DSN — server project | env | Rotate/regenerate DSN key |
| 13 | [ ] | Sentry DSN — iOS project | was committed in `.sample` xcconfigs (redacted in PR #128) | Rotate; update local gitignored xcconfigs |
| 14 | [ ] | Sentry DSN — web project | web env | |
| 15 | [ ] | Sentry auth token (`SENTRY_AUTH_TOKEN`) | GH secrets both repos + `.sentryclirc` | |
| 16 | [ ] | PostHog project key — iOS | was committed in `.sample`; ALSO hardcoded in `PostHogEnv.defaults` in `LuminaVaultClientApp.swift` (intentional, HER-242) | Rotate, then **update the source default** with the new token in the same PR |
| 17 | [ ] | PostHog key — web + `POSTHOG_OTEL_TOKEN` server | env / GH secret | |
| 18 | [ ] | App Store Connect API key (fastlane) | GH secret (base64 .p8) | Revoke in ASC, issue new |
| 19 | [ ] | fastlane match passphrase + LuminaVaultIOSSecrets access | GH secrets | Rotate passphrase (`match change_password`); consider `match nuke` + re-issue |
| 20 | [ ] | age backup identity | `secrets/` on VPS | New keypair; new backups → new recipient. KEEP old private key OFFLINE until old backups age out of retention (needed for restores) |
| 21 | [ ] | rclone remote credentials | `secrets/rclone.conf` | Rotate at storage provider; fresh bucket, old bucket read-only |
| 22 | [ ] | Discord webhook (`DISCORD_WEBHOOK_URL`) | GH secret | Regenerate |
| 23 | [ ] | GHCR fine-grained PATs (beyond `GITHUB_TOKEN`) | wherever issued | Revoke/reissue |
| 24 | [ ] | better-auth scaffold secret (web, dormant) | web `.env` | Regenerate before feature ever ships |
| 25 | [ ] | RevenueCat: verify no secret keys exposed (public `appl_` SDK key is fine) | dashboards | Sanity check only |

**Verification:** after each rotation, probe the OLD credential where feasible
(expect 401/revoked). Track anomalies in Sentry for 48h after the JWT rotation.

## C. Hardening landed with this incident (Phase 0 PRs)

- [x] C1. iOS: leaked PostHog token + Sentry DSN redacted from committed `.sample` xcconfigs; hardcoded Sentry fallback DSN removed (client PR #128, merged).
- [x] C2. iOS CI: pinned simulator destination replaces the exit-70 discovery guard; SwiftLint pinned (PR #128).
- [ ] C3. Server CI: xunit-aware test wrapper so test jobs can become required checks (PR #146).
- [ ] C4. Deploy gate: manual dispatch now verifies the commit's check runs unless bypass phrase typed (PR #147).
- [ ] C5. After PR #146 is green on consecutive runs: add `Unit Tests` to required status checks on `main`/`dev` (branch protection).
- [ ] C6. After 3 green client PRs: re-add `Run Tests` to required checks on client `main`/`development`.

## D. Structural follow-up (deployment modernization plan)

Phases 1–4 of the approved plan replace the suspect prod box with a
Terraform-provisioned k3s node (rebuild-from-code, GitOps deploys, sealed
secrets) and retire this estate. See `~/.claude/plans/quirky-watching-liskov.md`
(plan of record) — the Infra repo will carry the canonical copy.

## Decision log

- Rotation over git-history rewrite: the leaked classes (PostHog token, Sentry
  DSN) are client-observable identifiers; rotation kills their value, a
  `filter-repo` rewrite would break every clone for no security gain.
- `LV_SECRET_MASTER_KEY` (row 6) intentionally sequenced late: requires a
  re-encryption pass over SecretBox-stored tenant secrets; rotating it without
  that pass bricks stored BYOK keys.
