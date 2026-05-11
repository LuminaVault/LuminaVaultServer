import FluentKit
import SQLKit

/// HER-193 — per-skill daily run cap state. Extends `skills_state` (M19)
/// with a counter and an opportunistic reset stamp. `capability: high`
/// skills (pattern / contradiction / belief) burn ~$0.05-0.15 per call on
/// Sonnet; without per-skill caps, abusive use drains Pro-tier margin.
///
/// Reset is opportunistic — `daily_run_reset_at` is checked on every
/// `SkillRunCapGuard.checkAndIncrement` and rolled forward to the next
/// user-local midnight when expired. No cron needed.
struct M26_AddSkillsStateDailyRunCap: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE skills_state
            ADD COLUMN IF NOT EXISTS daily_run_count INT NOT NULL DEFAULT 0,
            ADD COLUMN IF NOT EXISTS daily_run_reset_at TIMESTAMPTZ NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE skills_state
            DROP COLUMN IF EXISTS daily_run_count,
            DROP COLUMN IF EXISTS daily_run_reset_at
        """).run()
    }
}
