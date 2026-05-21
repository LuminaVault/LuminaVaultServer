import FluentKit
import SQLKit

/// HER-37 Slice D — persisted proactive findings ("what Lumina noticed").
/// Backs `/v1/insights`, `/v1/insights/synthesis/latest`, and the
/// `Pattern Spotlight` + `Weekly Synthesis` Think-tab surfaces.
///
/// Schema mirrors the wire shape from `InsightDTO` (LuminaVaultShared)
/// including the HER-37 additions: `section` adds `this_month`, and the
/// `period_start` / `period_end` columns demarcate the analytical
/// window for synthesis rows (NULL for pattern rows).
struct M46_CreateInsight: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS insights (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            section TEXT NOT NULL,
            headline TEXT NOT NULL,
            summary TEXT NOT NULL,
            source_memory_ids UUID[] NOT NULL DEFAULT '{}',
            period_start TIMESTAMPTZ,
            period_end TIMESTAMPTZ,
            dismissed_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_insights_active
            ON insights (tenant_id, section, created_at DESC)
            WHERE dismissed_at IS NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS insights").run()
    }
}
