# Startup & Onboarding (HER-30)

This document explains how a developer goes from `git clone` to a working
LuminaVaultServer stack in one command, what `setup.sh` actually does, which
CLI subcommands ship with the binary, and how to recover when something
breaks.

## TL;DR

```bash
git clone <repo>
cd LuminaVaultServer
cp .env.example .env                # then edit JWT_HMAC_SECRET + BOOTSTRAP_ADMIN_*
./setup.sh                          # idempotent — re-run any time
```

When `setup.sh` exits to its `exec swift run App` step, the HTTP API is up
on `http://localhost:8080`. Ctrl-C stops the server; `make dev-down`
stops the Docker stack.

## What `setup.sh` Does

`setup.sh` lives at the repo root and is the one-click entry point. It
orchestrates everything required to bring a fresh checkout to a running
state. Each step is idempotent — safe to re-run.

| # | Step | Failure mode |
|---|------|--------------|
| 1 | **Preflight**: requires `docker`, `swift` (≥ 6.2), `docker compose` v2 plugin. Copies `.env.example` → `.env` if missing. | Fails fast with a red `[setup]` line. |
| 2 | **Data dirs**: `mkdir -p data/hermes/profiles data/postgres18 data/luminavault`. | Re-runnable. |
| 3 | **Compose up**: `docker compose up -d postgres hermes jaeger`. | Surfaces compose errors verbatim. |
| 4 | **Postgres gate**: polls `pg_isready` up to 60s. | Aborts with "postgres did not become ready within 60s". |
| 5 | **Migrate**: `swift run App migrate` runs every Fluent migration registered in `Sources/App/Migrations/Migrations.swift`. | Bubbles SQL errors. |
| 6 | **Bootstrap admin** *(optional)*: only when `BOOTSTRAP_ADMIN_EMAIL` and `BOOTSTRAP_ADMIN_PASSWORD` are set. Creates (or promotes) the admin user. | Warns and skips when env unset. |
| 7 | **Serve**: `exec swift run App` — foreground server. | Ctrl-C stops it. |

The script intentionally **does not** invoke the interactive
`make setup-hermes` wizard. The filesystem Hermes gateway only requires
`data/hermes/profiles/` to exist; per-tenant `profile.json` files are
written on demand by `FilesystemHermesGateway.provisionProfile` during
signup.

## CLI Subcommands

The `App` binary recognizes a first positional argument as a one-shot
subcommand instead of booting the HTTP server (see `Sources/App/App.swift`).
Subcommands read the same configuration chain as the server
(CLI args → env → `.env` → in-memory defaults).

### `swift run App migrate`

Runs every pending Fluent migration registered in
`Sources/App/Migrations/Migrations.swift` and exits.

- **Required env**: `POSTGRES_HOST`, `POSTGRES_USER`, `POSTGRES_PASSWORD`,
  `POSTGRES_DATABASE`, `POSTGRES_PORT` (all defaulted in `.env.example`).
- **Flags**: `--revert` runs `Fluent.revert()` (rolls back the last batch).
- **Idempotent**: re-running with no pending migrations is a no-op.
- **Use it for**: setup.sh, CI bootstrap, prod deploys where
  `FLUENT_AUTOMIGRATE=false` is the safer default.

```bash
swift run App migrate
swift run App migrate --revert
```

### `swift run App bootstrap-admin`

Idempotently seeds (or promotes) the initial admin user.

- **Required env**: `BOOTSTRAP_ADMIN_EMAIL`, `BOOTSTRAP_ADMIN_PASSWORD`
  (≥ 12 chars), `JWT_HMAC_SECRET`.
- **Optional env**: `BOOTSTRAP_ADMIN_USERNAME` (default `admin`).
- Existing email → flips `is_admin` and `is_verified` to true; no duplicate.
- New email → calls `AuthService.register` so trial defaults, Hermes
  profile provision (soft-fail), and SOUL.md initialization all run, then
  promotes the row.
- **Output**: single JSON line with `email`, `userID`, `username`,
  `created`, `isAdmin`, `isVerified`.

```bash
BOOTSTRAP_ADMIN_EMAIL=admin@local.dev \
BOOTSTRAP_ADMIN_PASSWORD=changeme123! \
  swift run App bootstrap-admin
```

### `swift run App backfill-hermes-profiles`

Pre-existing (HER-29) — walks every `users` row and ensures a `ready`
`hermes_profiles` row exists. Calls the same
`HermesProfileReconciler.reconcile()` as the daily in-process scheduler.

- **Idempotent**.
- **Use it for**: post-deploy reconciliation, manual healing after an
  outage of the Hermes gateway.

## Required Environment

Documented in `.env.example`. The most-load-bearing entries:

| Var | Default | Mandatory | Notes |
|-----|---------|-----------|-------|
| `JWT_HMAC_SECRET` | placeholder | yes | HS256 signing key. ≥ 32 chars; rotate via `JWT_KID`. |
| `POSTGRES_HOST` | `127.0.0.1` | no | `postgres` inside the compose network. |
| `POSTGRES_USER` / `_PASSWORD` / `_DATABASE` | `luminavault` | no | Match `docker-compose.yml`. |
| `FLUENT_AUTOMIGRATE` | `true` | no | setup.sh runs `migrate` explicitly, so this can safely be `false`. |
| `HERMES_GATEWAY_KIND` | `filesystem` | no | `logging` for tests; `filesystem` for dev/prod. |
| `HERMES_DATA_ROOT` | `/app/data/hermes` | no | Host-side `./data/hermes` is mounted in. |
| `BOOTSTRAP_ADMIN_EMAIL` | empty | no | Triggers the admin seed step in setup.sh. |
| `BOOTSTRAP_ADMIN_PASSWORD` | empty | no | Required when `_EMAIL` is set. ≥ 12 chars. |
| `BOOTSTRAP_ADMIN_USERNAME` | `admin` | no | Lowercase, must pass `UsernamePolicy.validate`. |

## Migration Architecture

Migrations live under `Sources/App/Migrations/` and are listed in a single
helper at `Sources/App/Migrations/Migrations.swift`:

```swift
func registerMigrations(on fluent: Fluent) async {
    await fluent.migrations.add(M00_EnableExtensions())
    ...
    await fluent.migrations.add(M34_AddUserIsAdmin())
}
```

Both `buildApplication` (server boot) and `runMigrateCommand` (CLI) call
this helper, so the two paths cannot drift apart. Adding a new migration:

1. Create `MXX_<Description>.swift` next to the others.
2. Append `await fluent.migrations.add(MXX_<Description>())` to
   `registerMigrations`.

`FLUENT_AUTOMIGRATE=true` (the default) makes the server re-run pending
migrations on every boot. `setup.sh` prefers `migrate` as a separate step
so a broken migration fails fast before the HTTP server is launched, and
so prod deploys that leave `FLUENT_AUTOMIGRATE=false` can drive
migrations from CI.

## Admin RBAC Status

`bootstrap-admin` writes `is_admin=true` on the User row, but admin HTTP
routes are still gated by `AdminTokenMiddleware`
(`Sources/App/Middleware/AdminTokenMiddleware.swift`), which checks an
`X-Admin-Token` header against the `ADMIN_TOKEN` env var. The
`User.isAdmin` field is dormant infrastructure for the follow-up RBAC
ticket — swapping the middleware to read the JWT `isAdmin` claim is a
single-file change once that work is scheduled.

For now, use the seeded admin user for authenticated app flows (login,
profile, billing) and continue to send `X-Admin-Token: $ADMIN_TOKEN` for
the `/v1/admin/**` routes.

## Troubleshooting

**`postgres did not become ready within 60s`** — usually a port conflict.
Run `lsof -nP -iTCP:5433` and stop whatever else owns the host-side port.
If postgres-the-container is failing, `docker compose logs postgres` will
show why.

**`bootstrap-admin requires JWT_HMAC_SECRET to boot AuthService`** — the
admin seed has to sign a registration response. Set `JWT_HMAC_SECRET` (≥ 32
chars) in `.env` and re-run.

**`emailExists` / `usernameTaken` on the first run** — a previous run
left the row in the database. Re-running `bootstrap-admin` is the right
fix; it will detect the existing row and promote it idempotently.

**Hermes profile won't provision** — the gateway is soft-fail at signup
(see `AuthService.register`). The user is created; the profile row sits
in `status="error"` until the daily reconciler heals it or you run
`swift run App backfill-hermes-profiles` manually.

**The interactive Hermes wizard hangs CI** — that's `make setup-hermes`,
which `setup.sh` deliberately skips. Run it only in interactive shells
when you want to customize the Hermes container's own configuration.

## Resetting Local State

```bash
make dev-down           # stop containers
make clean              # rm .build + data/postgres18 + data/redis + data/hermes
git clean -fdx data/    # nuke any straggling tenant filesystem
./setup.sh              # rebuild from scratch
```

Resetting only the database (preserve build cache and tenant vault):

```bash
docker compose down -v postgres
rm -rf data/postgres18
./setup.sh
```

## File Map (HER-30)

| Path | Purpose |
|------|---------|
| `setup.sh` | Orchestrator (this doc's step-by-step). |
| `Sources/App/CLI/MigrateCommand.swift` | `migrate` / `migrate --revert`. |
| `Sources/App/CLI/BootstrapAdminCommand.swift` | `bootstrap-admin`. |
| `Sources/App/CLI/BackfillHermesProfilesCommand.swift` | `backfill-hermes-profiles` (HER-29, pre-existing). |
| `Sources/App/Migrations/Migrations.swift` | Single migration registration helper. |
| `Sources/App/Migrations/M34_AddUserIsAdmin.swift` | `users.is_admin` column. |
| `Sources/App/Models/User.swift` | `isAdmin: Bool` field. |
| `Makefile` | `setup` and `migrate` targets. |
| `.env.example` | `BOOTSTRAP_ADMIN_*` documentation. |
