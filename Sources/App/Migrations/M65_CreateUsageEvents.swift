import FluentKit
import SQLKit

/// Metrics-only usage ledger for non-token events that do not fit the
/// aggregate `usage_meter` shape, such as completed memory compile runs.
struct M65_CreateUsageEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M65Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS usage_events (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            metric          TEXT NOT NULL CHECK (metric IN ('memory_compile_run', 'memory_compile_file')),
            amount          BIGINT NOT NULL CHECK (amount >= 0),
            source          TEXT NOT NULL,
            idempotency_key TEXT NULL,
            metadata        JSONB NOT NULL DEFAULT '{}'::jsonb
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS usage_events_tenant_occurred_idx ON usage_events(tenant_id, occurred_at DESC)"#
        ).run()
        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS usage_events_tenant_metric_occurred_idx ON usage_events(tenant_id, metric, occurred_at DESC)"#
        ).run()
        try await sql.raw(
            #"CREATE UNIQUE INDEX IF NOT EXISTS usage_events_idempotency_idx ON usage_events(tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M65Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS usage_events").run()
    }
}

private enum M65Error: Error { case requiresSQL }
