#!/usr/bin/env bash
# HER-30 — one-click developer setup for LuminaVaultServer.
#
# git clone → ./setup.sh → working stack on localhost:8080.
#
# Steps:
#   1. Preflight (docker, swift, .env)
#   2. mkdir data/{hermes/profiles,postgres18}
#   3. docker compose up postgres + hermes + jaeger (detached)
#   4. Poll pg_isready until Postgres accepts connections
#   5. swift run App migrate                — explicit migration
#   6. swift run App bootstrap-admin        — only when BOOTSTRAP_ADMIN_EMAIL set
#   7. exec swift run App                   — foreground server (Ctrl-C to stop)
#
# Safe to re-run: every step is idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# --- Console helpers ---------------------------------------------------------
log()  { printf "\033[36m[setup]\033[0m %s\n" "$*"; }
warn() { printf "\033[33m[setup]\033[0m %s\n" "$*" >&2; }
fail() { printf "\033[31m[setup]\033[0m %s\n" "$*" >&2; exit 1; }

# --- 1. Preflight ------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not installed"
command -v swift  >/dev/null 2>&1 || fail "swift toolchain not installed (need 6.2+)"
if ! docker compose version >/dev/null 2>&1; then
    fail "'docker compose' (v2) plugin not available"
fi

if [[ ! -f .env ]]; then
    if [[ -f .env.example ]]; then
        warn ".env missing — copying from .env.example"
        cp .env.example .env
        warn "Edit .env and set a real JWT_HMAC_SECRET before re-running for production-like use."
    else
        fail ".env and .env.example both missing"
    fi
fi

# shellcheck disable=SC1091
set -a
. ./.env
set +a

if [[ -z "${JWT_HMAC_SECRET:-}" || "${JWT_HMAC_SECRET}" == "change-me-32-chars-minimum-do-not-use-in-prod" ]]; then
    warn "JWT_HMAC_SECRET is unset or the placeholder. Local dev will start, but treat this as insecure."
fi

# --- 2. Per-tenant data dirs -------------------------------------------------
log "ensuring data directories"
mkdir -p data/hermes/profiles data/postgres18 data/luminavault

# --- 3. Compose up (postgres + hermes + jaeger) ------------------------------
log "starting infrastructure (postgres, hermes, jaeger)"
docker compose up -d postgres hermes jaeger

# --- 4. Postgres health gate -------------------------------------------------
PG_USER="${POSTGRES_USER:-hermes}"
PG_DB="${POSTGRES_DATABASE:-hermes_db}"
log "waiting for postgres ($PG_USER@$PG_DB)"
for _ in $(seq 1 60); do
    if docker compose exec -T postgres pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
        log "postgres ready"
        break
    fi
    sleep 1
done
if ! docker compose exec -T postgres pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
    fail "postgres did not become ready within 60s"
fi

# --- 5. Migrate --------------------------------------------------------------
log "running fluent migrations"
swift run App migrate

# --- 6. Bootstrap admin (optional) -------------------------------------------
if [[ -n "${BOOTSTRAP_ADMIN_EMAIL:-}" && -n "${BOOTSTRAP_ADMIN_PASSWORD:-}" ]]; then
    log "seeding admin user ($BOOTSTRAP_ADMIN_EMAIL)"
    swift run App bootstrap-admin
else
    warn "skipping admin seed — set BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD to enable"
fi

# --- 7. Foreground server ----------------------------------------------------
cat <<EOF

================================================================
LuminaVaultServer is ready.
  API:        http://localhost:${HTTP_PORT:-8080}
  Jaeger UI:  http://localhost:16686
  Postgres:   127.0.0.1:5433 (host-side)
  Stop:       Ctrl-C  (then 'make dev-down' to stop containers)
================================================================
EOF

exec swift run App
