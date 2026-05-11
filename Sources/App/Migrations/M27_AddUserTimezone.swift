import FluentKit
import SQLKit

/// HER-170 — adds `users.timezone TEXT NOT NULL DEFAULT 'UTC'`.
///
/// CronScheduler resolves each `(user, skill)` cron expression in the
/// user's timezone so `0 7 * * *` means 07:00 wherever that user actually
/// lives, not 07:00 UTC. iOS sends the IANA name (`Europe/Lisbon`) at
/// signup; users without one fall back to UTC.
struct M27_AddUserTimezone: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            #"ALTER TABLE users ADD COLUMN IF NOT EXISTS timezone TEXT NOT NULL DEFAULT 'UTC'"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(#"ALTER TABLE users DROP COLUMN IF EXISTS timezone"#).run()
    }
}
