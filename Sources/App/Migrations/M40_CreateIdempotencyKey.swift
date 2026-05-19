import FluentKit
import SQLKit

/// HER-39 — `idempotency_keys` table backs the cross-request idempotency
/// middleware. Stores the captured response of a mutating request so a retry
/// with the same `(tenant_id, key)` can be replayed without re-executing the
/// handler.
///
/// Schema notes:
/// - PK is the synthetic `id` UUID. The semantic uniqueness constraint is
///   `(tenant_id, key)` — enforced via a unique index, NOT a composite PK, so
///   Fluent's standard model APIs work and tenant isolation is the same as
///   every other `TenantModel`.
/// - `response_body` is `BYTEA`. Capped to 1 MiB at write-time by the
///   middleware; replays larger than that skip persistence entirely.
/// - `expires_at` carries a TTL (default 24 h). A follow-up ticket adds the
///   janitor service that reaps expired rows hourly.
struct M40_CreateIdempotencyKey: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS idempotency_keys (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL,
            key UUID NOT NULL,
            request_hash TEXT NOT NULL,
            response_status INTEGER NOT NULL,
            response_content_type TEXT,
            response_body BYTEA NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            expires_at TIMESTAMPTZ NOT NULL
        )
        """).run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_idempotency_keys_tenant_key
        ON idempotency_keys (tenant_id, key)
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_idempotency_keys_expires_at
        ON idempotency_keys (expires_at)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_idempotency_keys_expires_at").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_idempotency_keys_tenant_key").run()
        try await sql.raw("DROP TABLE IF EXISTS idempotency_keys").run()
    }
}
