import FluentKit
import SQLKit

/// HER-Reminders — user-scheduled timed messages. Backs `/v1/reminders` and
/// the `ReminderScheduler` push fan-out. The partial index on
/// `(tenant_id, fire_at)` WHERE `fired_at IS NULL` keeps the per-minute
/// "what's due now" scan cheap as the table grows.
struct M63_CreateReminder: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS reminders (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            fire_at TIMESTAMPTZ NOT NULL,
            recurrence_cron TEXT,
            fired_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_reminders_due
            ON reminders (tenant_id, fire_at)
            WHERE fired_at IS NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS reminders").run()
    }
}
