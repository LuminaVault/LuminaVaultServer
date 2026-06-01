import FluentKit
import SQLKit

/// Lumina Jobs P1 — persist a skill run's rendered output so the iOS app can
/// show job *results*, not just status. Previously `skill_run_log` stored only
/// audit columns; the markdown output was dispatched (vault/APNS/email) but
/// never saved, so the client had nothing to render. `blocks` (structured
/// output, P2) is added here too as nullable JSONB to avoid a second migration.
struct M66_AddSkillRunLogOutput: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skill_run_log ADD COLUMN IF NOT EXISTS markdown TEXT").run()
        try await sql.raw("ALTER TABLE skill_run_log ADD COLUMN IF NOT EXISTS blocks JSONB").run()
        try await sql.raw("ALTER TABLE skill_run_log ADD COLUMN IF NOT EXISTS space_id UUID").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skill_run_log DROP COLUMN IF EXISTS markdown").run()
        try await sql.raw("ALTER TABLE skill_run_log DROP COLUMN IF EXISTS blocks").run()
        try await sql.raw("ALTER TABLE skill_run_log DROP COLUMN IF EXISTS space_id").run()
    }
}
