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
swift run App
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
