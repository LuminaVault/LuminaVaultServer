import FluentKit
import SQLKit

/// HER-247 — per-skill APNS category preference. Stored on `skills_state`
/// so a user can pick whether `daily-brief` pushes as a `digest` or a
/// `nudge` (or neither). NULL preserves the manifest default.
struct M42_AddSkillsStateApnsCategory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE skills_state
        ADD COLUMN IF NOT EXISTS apns_category TEXT
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        ALTER TABLE skills_state
        DROP COLUMN IF EXISTS apns_category
        """).run()
    }
}
