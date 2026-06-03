import FluentKit
import SQLKit

/// M75 One-shot jobs (#10) — adds `run_at` to `skills_state`. A job with
/// `run_at` set and no cron schedule is a one-shot: `CronScheduler` fires it
/// once when `now >= run_at` (catch-up, like reminders) then disables the row.
/// Null for recurring (cron) and built-in skills.
struct M75_AddSkillsStateRunAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS run_at TIMESTAMPTZ").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS run_at").run()
    }
}
