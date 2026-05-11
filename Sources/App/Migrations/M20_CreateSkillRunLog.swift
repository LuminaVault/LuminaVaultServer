import FluentKit
import SQLKit

/// Append-only audit + cost-attribution log for skill executions. One row
/// per `SkillRunner.run(...)` invocation regardless of trigger source
/// (manual, cron, event). Captures `mtok_in`/`mtok_out` from provider
/// response headers so the UsageMeter can compute per-skill cost reports.
///
/// Indexed by `(tenant_id, started_at DESC)` to make "show me the last
/// N runs for this user" queries cheap without a sort.
struct M20_CreateSkillRunLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS skill_run_log (
                id UUID PRIMARY KEY,
                tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                source TEXT NOT NULL,
                name TEXT NOT NULL,
                started_at TIMESTAMPTZ NOT NULL,
                ended_at TIMESTAMPTZ,
                status TEXT NOT NULL,
                error TEXT,
                model_used TEXT,
                mtok_in INTEGER NOT NULL DEFAULT 0,
                mtok_out INTEGER NOT NULL DEFAULT 0
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_skill_run_log_tenant_started
            ON skill_run_log (tenant_id, started_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_skill_run_log_tenant_started").run()
        try await sql.raw("DROP TABLE IF EXISTS skill_run_log").run()
    }
}
