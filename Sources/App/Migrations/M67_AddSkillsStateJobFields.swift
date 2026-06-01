import FluentKit
import SQLKit

/// Lumina Jobs P3 — chat-created jobs are vault cron skills. Their target
/// Space and domain (for P4 filing + Jobs grouping/styling) are recorded on
/// `skills_state` so the scheduler/runner can resolve them without re-parsing
/// the SKILL.md. Both nullable; built-in skills leave them null.
struct M67_AddSkillsStateJobFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS domain TEXT").run()
        try await sql.raw("ALTER TABLE skills_state ADD COLUMN IF NOT EXISTS space_id UUID").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS domain").run()
        try await sql.raw("ALTER TABLE skills_state DROP COLUMN IF EXISTS space_id").run()
    }
}
