# LuminaVaultServer — VPS Integration Guide

End-to-end operations runbook: from a clean Ubuntu VPS to a fully wired
Hummingbird + Postgres + Hermes stack with `POST /v1/llm/chat` returning a
real reply from the LLM.

> **Hetzner users:** start here, then read [`hetzner-deployment.md`](./hetzner-deployment.md)
> (HER-31) for sizing, cost, network, backup, and reverse-proxy details
> specific to Hetzner Cloud — currently the recommended primary host.

---

## 1. Stack at a glance

| Service | Image / source | Port (host) | Volume |
|---|---|---|---|
| `hummingbird` (this server) | local Dockerfile | `8080` | `./data/luminavault`, `./data/hermes`, `./secrets` |
| `postgres` | `pgvector/pgvector:pg18` | `5433` → `5432` | `./data/postgres18` |
| `hermes-agent` | `nousresearch/hermes-agent:latest` | `8642` (OpenAI gateway) | `./data/hermes` |
| `jaeger` | `jaegertracing/all-in-one:latest` | `16686` (UI), `4317`/`4318` (OTLP) | none (in-memory) |

> Redis is intentionally **not** in the stack. See §1.4.

All containers share a single docker-compose network. `hummingbird` reaches
postgres at `postgres:5432`, hermes at `hermes:8642`, jaeger at `jaeger:4317`.
The host only needs to expose `8080` (or `443` via reverse proxy) and `5433`
if you want admin-side psql access.

Filesystem layout:

```
/opt/luminavault/                       # repo checkout
├── data/
│   ├── postgres18/                     # pg cluster (must persist)
│   ├── luminavault/tenants/<id>/raw/   # per-user file uploads
│   └── hermes/
│       └── profiles/<username>/        # one dir per user — Hermes profile state
│           └── profile.json
├── docker-compose.yml
├── docker-compose.production.yml
├── .env                                # secrets (NOT committed)
└── secrets/
    └── apns-key.p8                     # APNS auth key (NOT committed)
```

---

## 1.5 Postgres extension matrix

Image: **`pgvector/pgvector:pg18`** (NOT stock `postgres:18-alpine`).

| Extension | Status | Used by | How to add later |
|---|---|---|---|
| `uuid-ossp` | ✅ enabled (M00) | `gen_random_uuid` fallback | bundled with Postgres |
| `pgcrypto` | ✅ enabled (M00) | hash helpers | bundled with Postgres |
| `vector` (pgvector 0.8.2) | ✅ enabled (M00) | `memories.embedding` ANN search | already in image |
| `pg_trgm` | ✅ enabled (M00 + self-sufficient M13) | `vault_files.path` trigram fuzzy search | bundled with Postgres |
| **PostGIS** | ❌ not present | (none yet) | swap image to `postgis/postgis:18-3.5` (when released) **OR** build a multi-extension Dockerfile combining `pgvector` + `postgis` source. Useful only when location-tagged events arrive. |
| **TimescaleDB** | ❌ not present | (none yet) | upstream Timescale lags Postgres by ~6 months — no PG 18 build at the time of writing. Options: (a) downgrade to `timescale/timescaledb-ha:pg17-all` (which also bundles pgvector + PostGIS), losing PG 18 features; (b) wait for Timescale PG 18; (c) skip Timescale entirely and use native Postgres partitioning by `recorded_at` month on `health_events` once row count > 10M. |

**Verify what's loaded** at any time:

```
docker exec hermes-postgres psql -U hermes -d hermes_db -c \
  "SELECT extname, extversion FROM pg_extension"
docker exec hermes-postgres psql -U hermes -d hermes_db -c \
  "SELECT name FROM pg_available_extensions ORDER BY name"
```

**Migration matrix** (auto-applied on app boot when `fluent.autoMigrate=true`):

| # | Migration | Tables / Changes | Tenant scoped |
|---|---|---|---|
| M00 | EnableExtensions | uuid-ossp, pgcrypto, vector, pg_trgm | n/a |
| M01 | CreateUser | `users` | source-of-truth tenant id |
| M02 | CreateRefreshToken | `refresh_tokens` | ✅ |
| M03 | CreatePasswordResetToken | `password_reset_tokens` | ✅ |
| M04 | CreateMFAChallenge | `mfa_challenges` | ✅ |
| M05 | CreateOAuthIdentity | `oauth_identities` | ✅ |
| M06 | CreateMemory | `memories` (pre-vector) | ✅ |
| M07 | AddMemoryEmbedding | `memories.embedding vector(1536)` + ANN index | ✅ |
| M08 | CreateHermesProfile | `hermes_profiles` (1:1 with user) | ✅ |
| M09 | AddUsernameToUser | `users.username` unique | n/a |
| M10 | CreateDeviceToken | `device_tokens` (per-user APNS) | ✅ |
| M11 | CreateWebAuthnCredential | `webauthn_credentials` | ✅ |
| M12 | CreateSpace | `spaces` (user folders) | ✅ |
| M13 | CreateVaultFile | `vault_files` + trigram index | ✅ |
| M14 | CreateHealthEvent | `health_events` time-series | ✅ |

Every tenant-scoped table has `tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`. Deleting a user cascades to every row they own — including the memories vector index and on-disk Hermes profile rows. The filesystem side (`./data/hermes/profiles/<username>/`, `./data/luminavault/tenants/<userID>/raw/`) is NOT auto-cleaned; an ops job would `rm -rf` orphans separately.

## 2. Hosting strategy — choose ONE

### Option A: single docker-compose stack (RECOMMENDED for MVP)

Everything from §1 runs as containers on a single VPS via `docker compose up -d`.

**Pros**
- One command brings up the entire stack. One command tears it down.
- Identical topology in dev (laptop) and prod (VPS) — no environment drift.
- Backups are simple: stop the stack, snapshot `./data/`, restart.
- Single network namespace; no firewall holes between services.
- Fits comfortably on a €5–10/mo Hetzner CX22 (2 vCPU, 4 GB RAM, 40 GB SSD).

**Cons**
- One host = one fault domain. VPS reboot or disk failure takes everything down.
- No horizontal scaling. Postgres + Hermes share CPU/RAM with the app.
- No managed automated backups, security patching, or monitoring out of the box.
- Hermes inference is CPU-heavy; under sustained chat load on a 4 GB box you
  will hit OOM or thermal throttling. Plan to move Hermes off-box first when
  scaling.

**Use when**: solo dev, MVP, ≤100 users, willing to accept ~5–10 min recovery
from a VPS disaster (with backups in S3/B2).

### Option B: per-service systemd units (each service is a separate process / VPS)

Postgres on a managed provider (Neon, Supabase, RDS), Hermes on a GPU box,
Redis as a managed cache, Hummingbird as a single binary on a small VPS.

**Pros**
- Each component scales independently. Postgres can move to a 16 GB managed
  instance without touching the app.
- Real backup/PITR from the managed Postgres; you don't run pg_dump cron jobs.
- Hermes can sit on a GPU box (RTX 4090, A10) where chat latency drops to ~1s.
- One service crashing doesn't take down the others.

**Cons**
- 4× the moving parts. Network between services is the public internet (or a
  WireGuard mesh) — adds latency, security surface, and credentials to manage.
- Per-month cost goes from ~€5 to ~€50+ (managed Postgres alone is €15–30).
- Local dev no longer matches prod. You need `.env` overrides + a way to
  point local Hummingbird at managed services without breaking compose.
- Hermes profile filesystem layout (`./data/hermes/profiles/<username>/`)
  becomes harder: the Hermes box must mount the same volume Hummingbird
  writes to, OR you need to swap `FilesystemHermesGateway` for an
  `HTTPHermesGateway`. The HTTP gateway is currently a stub.

**Use when**: paying users, ≥100 active sessions/day, can spend €50–200/mo,
need 99.9% uptime SLA, or already have managed Postgres.

### Option C: Kubernetes / Docker Swarm (DEFER)

Out of scope for ≤1000 users. Re-evaluate once you have multiple VPSes and
need rolling deploys without downtime.

### Recommendation

Ship Option A. Migrate to Option B *one component at a time* when a real
bottleneck appears:
1. First move: Postgres → managed (data durability matters most).
2. Second: Hermes → GPU box (latency).
3. Third: app → 2× small VPSes behind a load balancer (uptime).

The codebase is already shaped for B (env-driven config, pluggable
`HermesGateway`), so the migration is an env-vars + DNS exercise rather than
a rewrite.

---

## 3. Provisioning a Hetzner VPS (one-time)

Tested on Ubuntu 22.04 LTS, CX22 plan (€5.83/mo, 2 vCPU, 4 GB RAM).

```bash
# As root, after first SSH login.

# 1. Create a non-root deploy user with sudo + docker access.
adduser luminavault
usermod -aG sudo luminavault
mkdir -p /home/luminavault/.ssh
cp ~/.ssh/authorized_keys /home/luminavault/.ssh/
chown -R luminavault:luminavault /home/luminavault/.ssh
chmod 700 /home/luminavault/.ssh
chmod 600 /home/luminavault/.ssh/authorized_keys

# 2. Disable root SSH + password auth.
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# 3. Firewall: only 22, 80, 443 open externally. Postgres stays internal.
apt-get update && apt-get install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# 4. Automatic security patching.
apt-get install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# 5. Docker + compose plugin.
curl -fsSL https://get.docker.com | sh
usermod -aG docker luminavault

# 6. Fail2ban for SSH brute-force.
apt-get install -y fail2ban
systemctl enable --now fail2ban
```

Then `ssh luminavault@<vps-ip>` and continue as the deploy user.

---

## 4. Deploying the stack

```bash
# As luminavault on the VPS.
cd /opt
sudo mkdir luminavault && sudo chown luminavault:luminavault luminavault
cd luminavault
git clone git@github.com:LuminaVault/LuminaVaultServer.git .

# Create .env (NOT committed). See §5 for the full matrix.
cat > .env <<'EOF'
POSTGRES_PASSWORD=...32-char-random...
JWT_HMAC_SECRET=...32-char-random...
HERMES_GATEWAY_KIND=filesystem
HERMES_GATEWAY_URL=http://hermes:8642
HERMES_DATA_ROOT=/app/data/hermes
HERMES_DEFAULT_MODEL=hermes-3
CORS_ALLOWEDORIGINS=https://app.luminavault.com,https://web.luminavault.com
WEBAUTHN_ENABLED=true
WEBAUTHN_RELYINGPARTYID=luminavault.com
WEBAUTHN_RELYINGPARTYORIGIN=https://app.luminavault.com
APNS_ENABLED=true
APNS_BUNDLEID=com.luminavault.ios
APNS_TEAMID=ABCD123XYZ
APNS_KEYID=ABC123DEFG
APNS_PRIVATEKEYPATH=/app/secrets/apns-key.p8
APNS_ENVIRONMENT=production
# --- Multi-provider auth ---
OAUTH_X_CLIENTID=...x-oauth2-client-id...
SMS_KIND=twilio
TWILIO_ACCOUNTSID=ACxxxxxxxxxxxx
TWILIO_AUTHTOKEN=...32-char...
TWILIO_FROMNUMBER=+15551234567
EOF
chmod 600 .env

mkdir -p secrets
# scp your APNS .p8 to /opt/luminavault/secrets/apns-key.p8

# Bring up the stack.
docker compose -f docker-compose.yml -f docker-compose.production.yml up -d --build
docker compose ps
```

### Reverse proxy + TLS via Caddy

Caddy auto-provisions Let's Encrypt certs. Run on the host (not in compose)
so it can serve port 443 without container port conflicts:

```bash
sudo apt install -y caddy
sudo tee /etc/caddy/Caddyfile <<'EOF'
api.luminavault.com {
    reverse_proxy localhost:8080

    # WebSocket upgrade is automatic in Caddy; explicit pass-through for clarity.
    @websocket {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    reverse_proxy @websocket localhost:8080
}
EOF
sudo systemctl reload caddy
```

Point `api.luminavault.com` A record at the VPS IP. Caddy issues the cert on
first request.

### Migrations

`buildApplication` calls `fluent.migrate()` on boot when `fluent.autoMigrate`
is unset (default `true`). Production should disable autoMigrate and run
migrations explicitly:

```bash
# .env
FLUENT_AUTOMIGRATE=false
```

```bash
# One-shot migration runner
docker compose run --rm hummingbird /app/.build/release/App migrate
# (Add the migrate subcommand or run a one-off SQL via psql if you don't have one yet.)
```

For now the stack auto-migrates on boot — fine for solo / small-team prod, but
plan to gate it before exposing to real users.

---

## 5. Environment variables (full matrix)

Read by `App+build.swift` via swift-configuration. Every key has a sane dev
default; prod must set the ones marked **required**.

| Key | Default | Required for prod | Notes |
|---|---|---|---|
| `LOG_LEVEL` | `info` | no | `debug`/`info`/`warning`/`error` |
| `FLUENT_ENABLED` | `true` | no | tests pass `false` |
| `FLUENT_AUTOMIGRATE` | `true` | recommend `false` | run migrations explicitly in prod |
| `POSTGRES_HOST` | `127.0.0.1` | yes (`postgres` in-compose) | |
| `POSTGRES_PORT` | `5432` | no | |
| `POSTGRES_USER` | `luminavault` | yes | `hermes` in current compose |
| `POSTGRES_PASSWORD` | `luminavault` | **yes** | rotate quarterly |
| `POSTGRES_DATABASE` | `luminavault` | yes | `hermes_db` in current compose |
| `JWT_HMAC_SECRET` | `""` (boot fails empty) | **yes** | 32-byte random; rotation = sign-out everyone |
| `JWT_KID` | `lv-default` | no | bump when rotating secret |
| `OAUTH_APPLE_CLIENTID` | `""` | optional | Sign in with Apple audience |
| `OAUTH_GOOGLE_CLIENTID` | `""` | optional | Google audience |
| `VAULT_ROOTPATH` | `/tmp/luminavault` | yes | per-tenant filesystem root |
| `HERMES_GATEWAYKIND` | `filesystem` | no | `logging` for tests, `filesystem` for prod |
| `HERMES_GATEWAYURL` | `http://hermes:8642` | yes | OpenAI-compatible endpoint |
| `HERMES_DATAROOT` | `/app/data/hermes` | yes | shared volume with hermes container |
| `HERMES_DEFAULTMODEL` | `hermes-3` | yes | verify with `curl http://hermes:8642/v1/models` |
| `CORS_ALLOWEDORIGINS` | `""` (`*`) | **yes for prod** | comma-separated; empty = wide-open dev mode |
| `WEBAUTHN_ENABLED` | `false` | optional | passkey routes mounted only when `true` |
| `WEBAUTHN_RELYINGPARTYID` | `""` | required if enabled | bare host, e.g. `luminavault.com` |
| `WEBAUTHN_RELYINGPARTYNAME` | `LuminaVault` | no | UI display name |
| `WEBAUTHN_RELYINGPARTYORIGIN` | `""` | required if enabled | full origin incl. scheme |
| `APNS_ENABLED` | `false` | optional | per-user push from `LLMController.chat` |
| `APNS_BUNDLEID` | `""` | required if enabled | iOS app bundle |
| `APNS_TEAMID` | `""` | required if enabled | 10-char Apple team ID |
| `APNS_KEYID` | `""` | required if enabled | 10-char APNS key ID |
| `APNS_PRIVATEKEYPATH` | `""` | required if enabled | path to `.p8` (mount as read-only) |
| `APNS_ENVIRONMENT` | `development` | yes | `production` for App Store builds |
| `OAUTH_X_CLIENTID` | `""` | optional | X (Twitter) OAuth 2.0 client ID. iOS handles redirect + PKCE; server only verifies the access_token via `/2/users/me`. |
| `SMS_KIND` | `logging` | yes for prod | `logging` (dev, logs OTP) \| `twilio` (real SMS). |
| `TWILIO_ACCOUNTSID` | `""` | required if `twilio` | Twilio account SID. |
| `TWILIO_AUTHTOKEN` | `""` | required if `twilio` | Twilio auth token. **Treat as a secret.** |
| `TWILIO_FROMNUMBER` | `""` | required if `twilio` | E.164 sender number from Twilio console. |
| `ADMIN_TOKEN` | `""` | recommended | Shared secret for `/v1/admin/*`. Empty disables admin endpoints (404). |

`.env` files use `KEY=value` (uppercase, underscores). swift-configuration
maps `OAUTH_APPLE_CLIENTID` → `oauth.apple.clientId`.

### Auth provider matrix

| Provider | Server endpoint | Status |
|---|---|---|
| Email + password | `POST /v1/auth/{register,login}` | ✅ shipped |
| Email magic-link | `POST /v1/auth/email/{start,verify}` | ✅ shipped |
| Phone OTP | `POST /v1/auth/phone/{start,verify}` | ✅ shipped |
| Apple OAuth | `POST /v1/auth/oauth/apple/exchange` (id_token) | ✅ shipped |
| Google OAuth | `POST /v1/auth/oauth/google/exchange` (id_token) | ✅ shipped |
| X (Twitter) OAuth 2.0 | `POST /v1/auth/oauth/x/exchange` (access_token) | ✅ shipped |
| WebAuthn / Passkey | `POST /v1/auth/webauthn/{register,authenticate}/{options,finish}` | ✅ shipped |
| Password reset (OTP) | `POST /v1/auth/{forgot,reset}-password` | ✅ shipped |
| MFA (login second factor) | `POST /v1/auth/mfa/{verify,resend}` | ✅ shipped |

---

## 6. First-message smoke test (Hermes chat)

Confirms the full path: client → Hummingbird → Hermes container → reply.

```bash
# 0. Stack is up
curl -s http://localhost:8080/health
# -> ok

# 1. Register a user (creates Hermes profile under data/hermes/profiles/alice/)
curl -s -X POST http://localhost:8080/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"alice@test.luminavault","username":"alice","password":"CorrectHorseBatteryStaple1!"}'
# -> { accessToken, refreshToken, ... }

ACCESS_TOKEN="...paste from above..."

# 2. Confirm the profile dir exists on disk
ls data/hermes/profiles/alice/
cat data/hermes/profiles/alice/profile.json
# -> { "username": "alice", "tenantID": "<uuid>", "createdAt": "...", "schemaVersion": 1 }

# 3. Send a chat message
curl -s -X POST http://localhost:8080/v1/llm/chat \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hi in 5 words."}],"temperature":0.7}'
# -> { id, model, message: { role: "assistant", content: "..." }, raw: { ... } }
```

If step 3 returns `502 hermes upstream error`:
- `docker logs --tail 100 hermes-agent` — was the request received?
- `docker exec hermes-agent ls /opt/data/profiles/` — does Hermes see the
  profile dir? (Container side is `/opt/data`, host side is `./data/hermes`.)
- `curl http://localhost:8642/v1/models` — does the gateway respond at all?

The `X-Hermes-Profile: <username>` header is the assumption to verify against
upstream Hermes if 502s persist. Swap to `model: "<username>/<base>"` or
query `?profile=<username>` in `DefaultHermesLLMService` if that's how the
real image expects per-profile routing.

---

## 7. Backups

The only durable state is **Postgres** and **`./data/hermes/profiles/`**.

```bash
# Daily Postgres dump
docker compose exec -T postgres pg_dump -U hermes hermes_db | gzip > /backup/pg-$(date +%F).sql.gz

# Daily hermes profiles snapshot (rsync to a B2/S3 bucket)
tar -czf /backup/hermes-$(date +%F).tar.gz -C data hermes
rclone copy /backup/ b2:luminavault-backups/
```

Restore drill (run quarterly!):

```bash
docker compose down
zcat /backup/pg-2026-04-01.sql.gz | docker compose exec -T postgres psql -U hermes -d hermes_db
tar -xzf /backup/hermes-2026-04-01.tar.gz -C data
docker compose up -d
```

Retention: 7 daily, 4 weekly, 6 monthly. Encrypt with `age` before uploading.

---

## 8. Monitoring

Already wired in compose:
- **Jaeger** at `http://<vps-ip>:16686` — distributed traces from Hummingbird
  via `swift-distributed-tracing` + OTEL exporter.
- **swift-metrics** counters/timers — currently bootstrapped to
  `DiscardingMetricsFactory`. Swap to `swift-prometheus` or OTLP metrics for
  prod observability:

  ```swift
  // App+build.swift
  MetricsSystem.bootstrap(PrometheusCollectorRegistry().swiftMetricsHandler)
  ```

  Then expose `/metrics` on a separate port, behind firewall (only Prometheus
  scraper can reach it).
- **Logs** — JSON to stderr; tail with `docker compose logs -f hummingbird`.
  Pipe to Loki or BetterStack for search.

Alerting (manual setup):
- HTTP probe: `curl -fsS https://api.luminavault.com/health`
- Disk: alert when `data/postgres18` > 80% of partition.
- Hermes: alert when `docker logs hermes-agent` spikes ERROR rate.

---

## 9. Hardening checklist

- [ ] `.env` has `chmod 600`, owned by `luminavault`.
- [ ] APNS `.p8` mounted read-only (`:ro` in compose volume).
- [ ] `JWT_HMAC_SECRET` is 32 bytes from `/dev/urandom`, NOT a memorable phrase.
- [ ] `POSTGRES_PASSWORD` rotated from the docker-compose default
      (`luminavault` / `super_secret_local_password_change_me`).
- [ ] `cors.allowedOrigins` set; no `*` in prod.
- [ ] `webauthn.relyingPartyOrigin` matches the real client origin (passkey
      flow silently fails on mismatch).
- [ ] Reverse proxy enforces HSTS, blocks insecure HTTP redirects.
- [ ] UFW closed on Postgres port 5433 from the public internet.
- [ ] `unattended-upgrades` running.
- [ ] `fail2ban` active on SSH.
- [ ] Daily backup cron, monthly restore drill.

---

## 10. Cost estimate (Hetzner CX22 + B2 backups, EU)

| Item | €/mo |
|---|---|
| Hetzner CX22 (2 vCPU, 4 GB) | 5.83 |
| Public IPv4 | 0.50 |
| Backups (Hetzner snapshot) | 1.16 |
| B2 cold storage (10 GB) | 0.45 |
| Domain (`.com`, amortised) | 1.00 |
| **Total** | **~9** |

Scaling break-even when chat throughput exceeds ~30 req/min sustained: move
Hermes to a dedicated GPU box (~€80/mo) before everything else.
