import FluentKit
import SQLKit

/// One row per tenant per local day: the proactive push that day's budget was
/// spent on. The primary key is the cap — `ProactivePushBudget.claim` inserts
/// with `ON CONFLICT DO NOTHING` and only the winner sends.
struct M141_CreateProactivePushLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS proactive_push_log (
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            day DATE NOT NULL,
            kind TEXT NOT NULL,
            sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            PRIMARY KEY (tenant_id, day)
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("proactive_push_log").delete()
    }
}

private enum MigrationError: Error { case requiresSQL }
