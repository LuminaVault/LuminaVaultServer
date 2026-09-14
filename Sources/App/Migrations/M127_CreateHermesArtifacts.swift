import FluentKit
import SQLKit

/// Harvested images, files and links from the tenant's Hermes sessions.
/// Unique per `(tenant_id, content_hash)` so a collect pass is idempotent.
struct M127_CreateHermesArtifacts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        CREATE TABLE IF NOT EXISTS hermes_artifacts (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            value TEXT NOT NULL,
            href TEXT NOT NULL,
            label TEXT NOT NULL,
            session_id TEXT NOT NULL,
            session_title TEXT NOT NULL,
            occurred_at TIMESTAMPTZ NOT NULL,
            content_hash TEXT NOT NULL,
            collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, content_hash)
        );
        CREATE INDEX IF NOT EXISTS hermes_artifacts_tenant_occurred_idx
            ON hermes_artifacts (tenant_id, occurred_at DESC);
        CREATE INDEX IF NOT EXISTS hermes_artifacts_tenant_kind_occurred_idx
            ON hermes_artifacts (tenant_id, kind, occurred_at DESC);
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS hermes_artifacts").run()
    }
}
