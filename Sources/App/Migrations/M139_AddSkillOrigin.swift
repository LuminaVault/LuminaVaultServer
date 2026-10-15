import FluentKit
import SQLKit

/// Where a job came from: the chat it was proposed in, or the Kanban card it
/// was promoted from. Nullable — every existing job predates it, and jobs
/// authored any other way have no single origin.
struct M139_AddSkillOrigin: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        ALTER TABLE skills_state
            ADD COLUMN origin_kind TEXT CHECK (origin_kind IN ('conversation', 'card')),
            ADD COLUMN origin_id UUID
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("skills_state")
            .deleteField("origin_kind")
            .deleteField("origin_id")
            .update()
    }
}

private enum MigrationError: Error { case requiresSQL }
