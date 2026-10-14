import FluentKit
import SQLKit

/// What kind of statement a memory is: a preference, a decision, a fact, or a
/// note. Nullable on purpose — every existing memory is unclassified, and
/// guessing a kind for them would put words in the user's mouth.
struct M138_AddMemoryKind: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        ALTER TABLE memories
            ADD COLUMN kind TEXT
            CHECK (kind IN ('preference', 'decision', 'fact', 'note'))
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("memories")
            .deleteField("kind")
            .update()
    }
}

private enum MigrationError: Error { case requiresSQL }
