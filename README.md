# ObsidianClaudeBrainServer

Backend API for ObsidianClaudeBrain — a lightweight, OpenAPI-first Hummingbird 2 server written in Swift 6.

## Responsibilities

- User authentication & subscription management
- Optional encrypted vault sync (multi-device)
- LLM call proxying / orchestration (optional, user keys)
- Analytics and memory graph computation (future)

## Tech stack

- **Swift 6** with structured concurrency
- **Hummingbird 2** — lightweight, modular HTTP server
- **swift-openapi-generator** — API contract defined in `openapi.yaml`, types and handlers generated at build time
- **swift-configuration** — layered config (CLI args → env vars → `.env` file → defaults)

## Project structure

```
Sources/
├── App/
│   ├── App.swift                          # Entry point (@main)
│   ├── App+build.swift                    # Application + router setup
│   ├── APIImplementation.swift            # OpenAPI handler implementations
│   └── OpenAPIRequestContextMiddleware.swift
└── AppAPI/
    ├── openapi.yaml                       # API contract (source of truth)
    ├── openapi-generator-config.yaml      # Generator config
    └── AppAPI.swift                       # Generated types (do not edit)
```

## Prerequisites

- Swift 6.2+
- macOS 15+ (for local dev)
- Docker (for deployment)

## Running locally

```bash
cp .env.example .env   # then edit JWT_HMAC_SECRET + BOOTSTRAP_ADMIN_*
./setup.sh
```

`setup.sh` is a one-click orchestrator (HER-30) that brings up Postgres,
Hermes, and Jaeger via Docker Compose, runs Fluent migrations, optionally
seeds an admin user, and execs the HTTP server. Every step is idempotent;
re-run it any time. See [`docs/startup.md`](docs/startup.md) for the full
walkthrough and CLI reference.

### Manual setup (fallback)

If you'd rather drive each step yourself:

```bash
make dev-up                                 # postgres + hermes + jaeger + hummingbird
swift run App migrate                       # apply Fluent migrations
swift run App bootstrap-admin               # optional: seed admin user
swift run App                               # foreground HTTP server
```

Configuration is read in this order: CLI args → environment variables → `.env` file → in-memory defaults.

```bash
# Example .env
LOG_LEVEL=debug
HTTP_PORT=8080
```

## Running with Docker

```bash
docker build -t obsidian-claude-brain-server .
docker run -p 8080:8080 obsidian-claude-brain-server
```

Local compose uses a PostgreSQL 18 image with pgvector and stores its data in `data/postgres18/`. If you previously ran the older local stack, delete the old `data/postgres/` volume before starting the new one.

## Redis in MVP

**Short answer: No — you do **not** need Redis for the MVP (and probably not for the first 6–12 months).**

You can safely **remove Redis entirely** right now. This simplifies your `docker-compose.yml`, reduces operational overhead, and makes the whole stack lighter without losing anything important for LuminaVault’s current scope.

### Why We Originally Included Redis
We added it for three classic reasons:
1. **Rate limiting** (protect Hermes + Postgres from abuse)
2. **Session / token blacklisting** (if you ever revoke JWTs)
3. **Caching** (frequent query results, compiled wiki summaries, etc.)

None of these are **must-haves** for MVP.

### Current Reality for LuminaVault

| Feature                  | Do you need Redis for it? | Alternative (good enough for MVP)                  | Verdict |
|--------------------------|---------------------------|----------------------------------------------------|---------|
| Rate limiting            | Nice-to-have             | In-memory rate limiter (Hummingbird built-in) or simple Postgres table | **No** |
| JWT sessions             | Not needed               | Stateless JWT (what we’re already using)           | **No** |
| Caching                  | Not critical             | Postgres materialized views or simple in-memory cache in Hummingbird | **No** |
| Background jobs          | Future only              | Later (when you add async kb-compile queue)       | Future |
| Real-time / pub-sub      | Future only              | WebSockets (if ever added)                         | Future |

Your traffic profile for the next year will be:
- Mostly single-user or small-team personal vaults
- Occasional `kb-compile` and queries
- Low concurrency

A single Hetzner VPS can easily handle this without Redis.

### Recommendation

**Remove Redis now** (cleanest stack):

Updated minimal `docker-compose.yml` services:
```yaml
services:
  postgres:
    # ... (unchanged)

  hermes:
    # ... (unchanged)

  hummingbird:
    # ... (unchanged)
    # Remove REDIS_URL from environment
```

**What to use instead right now:**

1. **Rate limiting** → Use the official Hummingbird in-memory rate limiter:
   ```swift
   app.add(middleware: RateLimitMiddleware(limit: 120, per: .minute))
   ```
   (or the Redis-backed one later if you ever need it)

2. **Simple caching** → Hummingbird has a built-in `Cache` protocol with in-memory backend. You can swap to Redis-backed later with one line change.

3. **Future background work** → When you need queues, add Redis (or PostgreSQL LISTEN/NOTIFY, or just a simple Swift actor queue) at that time.

### When You *Should* Re-add Redis

Re-introduce it only when you hit one of these milestones:
- You have >50 concurrent active users doing frequent compiles/queries
- You add background jobs (async kb-compile, nightly pattern analysis, etc.)
- You implement usage-based billing that needs reliable counters
- You add real-time WebSockets with many open connections

At that point it becomes worth the extra container.

**Bottom line for you right now**  
Keep the stack as simple as possible:  
**Postgres + Hermes + Hummingbird** (and the shared package we just set up).

## API contract

The API is defined in [`Sources/AppAPI/openapi.yaml`](Sources/AppAPI/openapi.yaml).  
Swift types and route stubs are generated automatically by `swift-openapi-generator` at build time — edit `openapi.yaml` to extend the API, then implement the new operations in `APIImplementation.swift`.

## Adding a new endpoint

1. Add the path + operation to `openapi.yaml`
2. Build (`swift build`) — the generator creates the Swift protocol method
3. Implement the method in `APIImplementation.swift`
4. Add a test in `Tests/AppTests/`

## Auth & Tenancy

LuminaVault is **tenant-first**: every domain row carries `tenant_id` (= the owning user's UUID) and every Fluent query routes through `Model.query(on:context:)`, which auto-applies `WHERE tenant_id = ?`. This makes cross-tenant data leaks impossible to introduce by forgetting a filter.

**Key types**

- `AppRequestContext` (`Sources/App/Context/AppRequestContext.swift`) — conforms to `AuthRequestContext` from hummingbird-auth. After `JWTAuthenticator` runs, `context.identity: User` is set; `context.requireTenantID()` returns the user's UUID or throws 401.
- `TenantModel` (`Sources/App/Models/TenantModel.swift`) — protocol every domain model conforms to. Adds `Model.query(on:tenantID:)` and `Model.query(on:context:)` overloads that prepend the tenant filter.
- `JWTAuthenticator` (`Sources/App/Auth/Middleware/JWTAuthenticator.swift`) — extracts `Bearer` JWT, verifies via `JWTKeyCollection`, hydrates `User`, sets `context.identity`.
- `ServiceContainer` (`Sources/App/Services/ServiceContainer.swift`) — typed DI bag passed into routers; carries `Fluent`, `JWTKeyCollection`, `JWKIdentifier`, OAuth client IDs. Repositories/services receive `Fluent` directly via constructor injection — no global state.

**Endpoints (v1)**

| Method | Path                                | Purpose |
|--------|-------------------------------------|---------|
| POST   | /v1/auth/register                   | Email+password sign-up |
| POST   | /v1/auth/login                      | Email+password (supports `mfa-auth-v1` capability header) |
| POST   | /v1/auth/refresh                    | Rotate access token (revokes old refresh) |
| POST   | /v1/auth/logout                     | Revoke refresh token |
| POST   | /v1/auth/mfa/verify                 | Submit OTP to satisfy challenge |
| POST   | /v1/auth/mfa/resend                 | Re-issue OTP |
| POST   | /v1/auth/forgot-password            | Send reset OTP to email |
| POST   | /v1/auth/resend-reset               | Re-issue reset OTP |
| POST   | /v1/auth/reset-password             | Submit OTP + new password |
| POST   | /v1/auth/oauth/{provider}/exchange  | Sign in via Apple/Google id_token |
| GET    | /v1/auth/me                         | Authenticated user profile (Bearer required) |

**JWT format**

HS256 signed `SessionToken` (`Sources/App/Auth/JWT/SessionToken.swift`) carrying `sub` (userId UUID = tenantID), `exp`, `jti`. Secret loaded from `JWT_HMAC_SECRET`. `kid` (`JWT_KID`) is included in the JOSE header to support key rotation.

**Adding a new tenant-scoped model**

```swift
final class MyThing: Model, TenantModel, @unchecked Sendable {
    static let schema = "my_things"
    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID   // REQUIRED
    // ...
}

// In a route:
let rows = try await MyThing.query(on: services.fluent.db(), context: ctx).all()
//                              tenant filter is implicit ^^^
```

Migrations must add a `tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE` column and an index on `tenant_id`.

**Vault filesystem & Hermes Profile**

Per-tenant raw markdown lives under `tenants/<tenantID>/raw/`. Each user owns exactly **one** Hermes Profile (1:1, fully isolated memory and state). The Hermes container is shared infrastructure; per-user Profiles inside it never cross. Profile binding is stored in `hermes_profiles` and provisioned on register/OAuth-create via `HermesProfileService.ensure(for:)` (idempotent).

**Semantic search (pgvector)**

`memories.embedding vector(1536)` is indexed with IVFFlat cosine. Queries route through `MemoryRepository.semanticSearch(...)`, which prepends `WHERE tenant_id = ?` BEFORE `ORDER BY embedding <=> ?` so the planner uses the composite `idx_memories_tenant_created` index. Cross-tenant vector leaks are blocked at the SQL layer.

**Rate limiting**

Hummingbird ships no built-in rate limiter; `RateLimitMiddleware` (`Sources/App/Middleware/RateLimitMiddleware.swift`) is a token-bucket on top of `PersistDriver` (in-memory for MVP, swap to Redis for multi-process). Per-route policies match StockPlanBackend semantics: 5/60s register-by-IP, 10/60s login, 30/60s refresh-by-tenant, etc.

**Dependency Injection**

This service is intentionally a single-process monolith for MVP deployment. DI is via:

1. **`ServiceContainer`** — process-level dependencies (Fluent, JWT keys, OAuth client IDs). Built once in `buildApplication`, passed into `buildRouter`.
2. **Constructor injection** — services and repositories receive their dependencies as `let` properties on stored structs. No global `Application.storage`.
3. **Per-request context** — `AppRequestContext` carries the authenticated identity. Repositories accept `context: AppRequestContext` for tenant-scoped operations.
4. **Protocols at boundaries** — `AuthService`, `AuthRepository`, `PasswordHasher`, `OAuthProvider`, `EmailOTPSender`, `OTPCodeGenerator`, `MFAService`, `HermesGateway` are all protocols, so tests inject fakes.

For a multi-process future, `ServiceContainer` is the only thing that needs to learn about discovery/clustering — call sites stay unchanged.

**Configuration**

Required env vars:

| Variable | Purpose |
|----------|---------|
| `POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE` | Database connection |
| `JWT_HMAC_SECRET` | HS256 signing secret (32+ chars) |
| `JWT_KID` | Key ID in JOSE header for rotation |
| `OAUTH_APPLE_CLIENTID` | Apple Sign-in Service ID (audience) |
| `OAUTH_GOOGLE_CLIENTID` | Google OAuth 2.0 client ID (audience) |
| `VAULT_ROOT_PATH` | Filesystem root for `tenants/<id>/raw/` |
| `HERMES_GATEWAY_URL` | Hermes container endpoint |
| `FLUENT_ENABLED` | Set `false` in tests to skip Fluent wiring |
| `FLUENT_AUTOMIGRATE` | Set `false` to skip migrate() at boot |

## Operations

### Backup & Recovery

**Automated backups** (Docker)

```bash
# Run at 2 AM daily (or via cron)
docker exec hermes-postgres pg_dump -U hermes hermes_db \
  --format=custom --compress=9 \
  > backups/hermes_db_$(date +%Y%m%d).dump

# Keep 30 days of rolling backups
find backups -name 'hermes_db_*.dump' -mtime +30 -delete
```

**Restore from backup**

```bash
docker exec hermes-postgres pg_restore -U hermes -d hermes_db \
  --format=custom --clean --if-exists backups/hermes_db_20260501.dump
```

**Point-in-time recovery**

Postgres WAL archiving (in `docker-compose.yml`):
```yaml
postgres:
  environment:
    POSTGRES_INITDB_ARGS: >
      -c wal_level=replica
      -c archive_mode=on
      -c archive_command='test ! -f /wal_archive/%f && cp %p /wal_archive/%f'
  volumes:
    - ./data/postgres18:/var/lib/postgresql
    - ./data/wal_archive:/wal_archive  # WAL segment archive
```

Then restore to a specific timestamp:
```bash
docker exec hermes-postgres pg_basebackup -U hermes -D - | \
  pg_wal_replay_timeline -t /path/to/timeline_history
```

### Monitoring & Observability

**Key metrics to watch** (via Prometheus, Datadog, or NewRelic)

| Metric | Alert Threshold | Meaning |
|--------|-----------------|---------|
| `postgres.connections.active` | > 90 | Close to connection pool limit |
| `postgres.query.duration_ms.p95` | > 500 | Slow queries affecting UX |
| `postgres.table_size_bytes{table="memories"}` | > 5GB | Vector table growing fast (review TTL) |
| `hummingbird.http.requests.duration_ms.p99` | > 1000 | API latency spike |
| `hermes.profile_provision_duration_ms` | > 5000 | Hermes container slow |
| `app.errors.tenant_isolation` | > 0 | **CRITICAL**: cross-tenant data leak |
| `app.errors.rate_limit_bypass` | > 0 | **CRITICAL**: rate limit broken |

**Logging for tenant-scoped failures**

All logs include:
- `request_id` (UUID, propagated via middleware)
- `tenant_id` (from JWT `sub` claim, propagated via context)
- `user_id` (if authenticated)
- `error_code` (structured error type)

Example structured log entry:
```json
{
  "level": "error",
  "message": "hermes profile provisioning failed",
  "request_id": "a1b2c3d4-...",
  "tenant_id": "user-123-...",
  "service": "HermesProfileService",
  "error_code": "HERMES_TIMEOUT",
  "duration_ms": 5120
}
```

**Enable query logs** (PostgreSQL)

```yaml
postgres:
  environment:
    POSTGRES_INITDB_ARGS: >
      -c log_statement=all
      -c log_min_duration_statement=200
```

Logs go to container stdout; ship to your log aggregator (CloudWatch, Loki, Datadog).

### Tenant Isolation Audit

Run quarterly to verify no cross-tenant queries leak data:

```sql
-- Check that all TenantModel tables have tenant_id NOT NULL
SELECT table_name, column_name
  FROM information_schema.columns
 WHERE table_name IN ('refresh_tokens', 'passwords', 'mfa_challenges', 'memories', 'hermes_profiles')
   AND column_name = 'tenant_id'
   AND is_nullable = 'YES'  -- should be empty!
;

-- Verify all TenantModel tables have tenant_id indexed
SELECT indexname, indexdef FROM pg_indexes
 WHERE tablename IN ('memories', 'refresh_tokens', 'oauth_identities')
   AND indexdef LIKE '%tenant_id%'
;
```

### Row-Level Security (RLS) — Future Migration

LuminaVault currently relies on **application-layer tenant filtering** via `TenantModel.query(on:context:)`. This is safe for single-tenant isolation but **not sufficient** for true multi-tenancy if you ever:
- Add on-premise deployments (customer runs entire stack)
- Host multiple SaaS customers with strong contractual isolation
- Hire employees who need RBAC within a tenant

**Plan for RLS migration** (no code changes needed):

1. **Enable RLS** on all `TenantModel` tables:
   ```sql
   ALTER TABLE memories ENABLE ROW LEVEL SECURITY;
   ALTER TABLE refresh_tokens ENABLE ROW LEVEL SECURITY;
   -- ... etc
   ```

2. **Create a policy** that mirrors your application filter:
   ```sql
   CREATE POLICY memories_tenant_isolation ON memories
     USING (tenant_id = CURRENT_USER_ID)  -- or set via set_config('app.tenant_id', ...)
     WITH CHECK (tenant_id = CURRENT_USER_ID);
   ```

3. **Pass tenant_id in transaction context** (from Fluent):
   ```swift
   try await db.transaction { tx in
     try await tx.query(raw: "SET app.tenant_id = '\(tenantID.uuidString)'").run()
     // ... all queries in this transaction now auto-filtered by RLS
   }
   ```

4. **Test RLS bypass** (verify no SQL injection can leak rows):
   ```bash
   # Try to read another tenant's row
   SELECT * FROM memories WHERE tenant_id != CURRENT_USER_ID;  -- 0 rows (RLS policy blocks it)
   ```

At that point, your application filter becomes **defense-in-depth**, and Postgres itself enforces isolation.

### Deployment Checklist

Before going live on a VPS:

- [ ] **Backups** — test restore from full and incremental backups
- [ ] **Monitoring** — set up alerts for connection pool, query latency, errors
- [ ] **TLS/HTTPS** — enable in Hummingbird + reverse proxy (nginx/Caddy)
- [ ] **Database hardening** — change default Postgres password, create read-only replica role for backups
- [ ] **Vault filesystem** — ensure `tenants/` directory is readable only by app (mode 750)
- [ ] **Secrets rotation** — plan for JWT key rotation (`JWT_KID` versioning + dual-key acceptance)
- [ ] **Rate limiting** — verify per-route limits are tuned to your traffic profile
- [ ] **Tenant isolation audit** — run the SQL checks above before launch
