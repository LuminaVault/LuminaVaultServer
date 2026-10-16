import FluentKit
import SQLKit

/// The one model-written card of a year or month recap, cached per user and
/// period so the model runs once per period rather than once per view. The
/// counted cards are not stored: they are cheap to recompute and always
/// current. Deleted with the user.
struct M143_CreateRecapThemes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS recap_themes (
            user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            period_key TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'fallback')),
            headline TEXT,
            sentence TEXT,
            themes TEXT[] NOT NULL DEFAULT '{}',
            attempts INT NOT NULL DEFAULT 0,
            requested_at TIMESTAMPTZ,
            generated_at TIMESTAMPTZ,
            PRIMARY KEY (user_id, period_key)
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS recap_themes").run()
    }
}

private enum MigrationError: Error { case requiresSQL }
