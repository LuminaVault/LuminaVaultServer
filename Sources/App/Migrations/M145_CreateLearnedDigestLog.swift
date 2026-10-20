import FluentKit
import SQLKit

/// One row per tenant per week: the "What I learned this week" digest that
/// week. The primary key is the cap — `LearnedDigestScheduler` inserts with
/// `ON CONFLICT DO NOTHING` and only the winner goes on to send. `week_start`
/// is the tenant's local Monday. `outcome` records what happened (`sent`,
/// `empty`, `opted_out`, `no_device`, `budget_spent`, `failed`); an empty week
/// still gets a row so it is not rebuilt every minute of the Sunday hour.
///
/// Also turns off the per-user scheduled jobs that the legacy-job migrator
/// made from `weekly-memo` and `health-correlate`. Both SKILL.md bodies are
/// `TODO HER-173` placeholders and are now manual only (no `schedule`); a
/// workflow the migrator already created would keep firing the placeholder
/// prompt for every user regardless. Only untouched copies are switched off
/// (still on their first published version); anything a user edited stays.
struct M145_CreateLearnedDigestLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS learned_digest_log (
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            week_start DATE NOT NULL,
            sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            outcome TEXT NOT NULL DEFAULT 'sent',
            PRIMARY KEY (tenant_id, week_start)
        )
        """).run()
        try await sql.raw("""
        UPDATE workflows w SET enabled = FALSE
        WHERE w.is_legacy_job
          AND w.enabled
          AND w.legacy_skill_name IN ('weekly-memo', 'health-correlate')
          AND NOT EXISTS (
              SELECT 1 FROM workflow_versions v
              WHERE v.workflow_id = w.id AND v.version > 1
          )
        """).run()
    }

    func revert(on database: any Database) async throws {
        // The workflows stay off: which ones were on before is not recorded,
        // and turning a placeholder prompt back on for everyone is the bug.
        try await database.schema("learned_digest_log").delete()
    }
}

private enum MigrationError: Error { case requiresSQL }
