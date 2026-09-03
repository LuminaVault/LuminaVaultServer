# Hand-off — Hermes Mirror (server, branch `feat/hermes-mirror`)

Status: implemented and tested on the server; **not pushed, not tagged**. The
branch builds only against a local `LuminaVaultShared` checkout until the
Shared tag below exists.

## Owner steps, in order

1. **Tag `LuminaVaultShared` `5.3.0`** from branch `feat/hermes-mirror-dtos`
   (commit `70ca33b`, additive minor: Hermes Mirror DTOs, `SkillSource.hermes`,
   `HermesCapabilities.dashboard`).
2. **Bump the server pin** in `LuminaVaultServer/Package.swift`:
   `.package(url: "https://github.com/LuminaVault/LuminaVaultShared.git", from: "5.3.0")`
   (update the comment above it), then `swift package resolve` and commit
   `Package.swift` + `Package.resolved` on `feat/hermes-mirror`. The client
   repo takes the same bump when the iOS work starts.
   Local builds before the tag: `swift package edit LuminaVaultShared --path ../LuminaVaultShared`
   (do not commit the resulting `Package.resolved` / `Packages/` changes).
3. **Merge order:** `fix/audit-2026-09-p0` first (independent), then
   `feat/hermes-mirror`. Both branch from `main` @ `e871f2e`.
4. **Decrypt prod `api-env`** and check `RATE_LIMIT_STORAGE_KIND`. After
   `fix/audit-2026-09-p0` the value `redis` **requires** `REDIS_URL`
   (`redis://` or `valkey://`); a missing/invalid URL fails the boot with a
   thrown `RateLimitStorageConfigurationError` naming both keys, and an
   unreachable Valkey fails the readiness probe in the ServiceGroup. `memory`
   stays the default. No new config keys were added for the mirror.
5. **Migrations:** M114–M116 (`hermes_mirror_state`, `hermes_mirrored_skills`,
   `hermes_mirrored_jobs`) run with `fluent.autoMigrate` / `make migrate`.
6. **Infra:** no manifest changes. Verify `cluster/network-policies` allows API
   egress 443 (BYO dashboards are outbound HTTPS, same as the cron bridge).
   `HERMES_GATEWAY_KIND=filesystem` stays for the managed path.
7. **Hermes image:** the kb-* skills moved to
   `Sources/App/Resources/HermesSkills/`; `docker/hermes.Dockerfile` and the
   `hermes-image` workflow path filter already point there. Rebuild with
   `make hermes-image`.
8. Then start the iOS and web agents (plan tasks 9–10) against the tagged DTOs.

## What shipped (server)

- `Hermes/Mirror/`: transport protocol, `HermesDashboardClient` (dashboard
  `/api/*`), `RemoteHermesTransport` (BYO), `FilesystemHermesTransport`
  (managed PVC + gateway sessions), transport factory, `HermesMirrorService`
  (sync with tombstones, vault detect/import/create, sessions import, nightly
  compile job), `HermesMirrorController`, `HermesMirrorRefreshWorker`,
  `HermesBundledSkills`, `HermesDashboardCredentialStore`.
- `HermesRemoteCapabilitiesService` probes the dashboard auth mode
  (`bearer` / `oauth_only` / `unauthorized` / `unreachable`); `HermesConfigController`
  re-probes after `PUT` and `POST /test`.
- `CronBridgeService` BYO calls go through the same dashboard client; routes
  and error codes unchanged. `HermesSkillsClient` is on AsyncHTTPClient.
- `GET /v1/skills` appends mirrored skills (`source: hermes`, id `hermes-<name>`);
  `/run` on them answers 400 `hermes_skill_runs_on_hermes`.
- `openapi.yaml` carries every new path/schema (web types regenerate from it).
  Run `make bruno-regen` after merge if the Bruno collection is kept current.

## Routes

`/v1/hermes/mirror`: `GET status`, `POST sync {scope}`, `GET skills`,
`PUT skills/{name} {enabled}`, `GET jobs` (live | snapshot),
`POST jobs/install-compile`, `POST vault/import {vaultPath?}`,
`POST vault/create`, `POST vault/import-sessions`.

Stable error codes: `hermes_dashboard_auth_mode_unsupported` (502; dashboard is
behind the OAuth gate — bind it to loopback behind the user's own TLS proxy or
tunnel), `hermes_dashboard_unauthorized`, `hermes_dashboard_unreachable`,
`hermes_mirror_invalid_path` (400), `hermes_vault_not_found` (404),
`hermes_mirror_busy` (409), `hermes_skill_runs_on_hermes` (400).

## BYO dashboard requirement (adoption risk)

The Hermes dashboard accepts `Authorization: Bearer <HERMES_DASHBOARD_SESSION_TOKEN>`
only when bound to loopback. A non-loopback bind switches to the OAuth /
password gate, which has no bearer path — the probe reports `oauth_only` and
every write/cron/fs/sessions capability is off. Users expose the loopback
dashboard through their own reverse proxy or tunnel (see `docs/byo-hermes.md`).
This applies to the pre-existing cron bridge as well.

## Verification run (2026-09-03, macOS, local Postgres on :5433)

- `swift build` — ok.
- `swift test --filter "HermesMirror|HermesDashboard|FilesystemHermesTransport|HermesBundledSkills|M114HermesMirror"` — see final report.
- `swift test --filter "RateLimitStorageFactoryTests|PostHogHTTPClientTests"` (branch `fix/audit-2026-09-p0`) — 20 passed.
- `swiftformat --lint` clean on touched files; swiftlint clean on new files.
- `make test` (Docker full suite) not run — see final report.
