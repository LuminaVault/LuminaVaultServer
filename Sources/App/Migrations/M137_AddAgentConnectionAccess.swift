import FluentKit
import SQLKit

/// Splits agent keys into read-only and read-write.
///
/// Every existing key could already call the writing tools (`index`,
/// `calendar_create`, `reminder_create`), so existing rows get `read_write`:
/// an agent that works today must keep working after the upgrade. The column
/// default then becomes `read`, so a row inserted without an explicit value
/// fails safe. The service always sets it explicitly anyway.
struct M137_AddAgentConnectionAccess: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        ALTER TABLE agent_connections
            ADD COLUMN access TEXT NOT NULL DEFAULT 'read_write'
            CHECK (access IN ('read', 'read_write'))
        """).run()
        try await sql.raw("""
        ALTER TABLE agent_connections ALTER COLUMN access SET DEFAULT 'read'
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("agent_connections")
            .deleteField("access")
            .update()
    }
}

private enum MigrationError: Error { case requiresSQL }
