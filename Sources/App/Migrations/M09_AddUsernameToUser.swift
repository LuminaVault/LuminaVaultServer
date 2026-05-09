import FluentKit
import SQLKit

/// Adds the `username` column to `users`. Each user gets a unique, slug-safe
/// handle that doubles as the Hermes profile name (see `HermesProfileService`).
///
/// Backfill strategy (dev): synthetic `user-<8hex>` derived from each row's UUID.
/// For real production data with existing users, replace the UPDATE with a
/// dedicated, operator-driven backfill before running this migration.
struct M09_AddUsernameToUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("ALTER TABLE users ADD COLUMN IF NOT EXISTS username TEXT").run()
        try await sql.raw(
            "UPDATE users SET username = 'user-' || substring(id::text, 1, 8) WHERE username IS NULL"
        ).run()
        try await sql.raw("ALTER TABLE users ALTER COLUMN username SET NOT NULL").run()
        try await sql.raw(
            "CREATE UNIQUE INDEX IF NOT EXISTS users_username_key ON users(username)"
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP INDEX IF EXISTS users_username_key").run()
        try await sql.raw("ALTER TABLE users DROP COLUMN IF EXISTS username").run()
    }
}

private enum MigrationError: Error { case requiresSQL }
