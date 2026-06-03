import FluentKit
import SQLKit

/// Calendar event cache — backs both Apple EventKit selective-sync
/// (`source = "apple_eventkit"`) and HER-340 Google Calendar
/// (`source = "google"`). The unique `(tenant_id, source, external_id)` key is
/// the upsert target so deltas from each source are idempotent and never
/// collide. Cancelled events are tombstoned via `status = "cancelled"`.
///
/// Indexed on `(tenant_id, starts_at)` for the day-window read that powers the
/// `calendar_query` Hermes tool ("events between X and Y for user U").
struct M79_CreateCalendar: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS calendar_events (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            source TEXT NOT NULL,
            external_id TEXT NOT NULL,
            calendar_id TEXT,
            title TEXT NOT NULL,
            notes TEXT,
            location TEXT,
            starts_at TIMESTAMPTZ NOT NULL,
            ends_at TIMESTAMPTZ NOT NULL,
            all_day BOOLEAN NOT NULL DEFAULT FALSE,
            status TEXT NOT NULL DEFAULT 'confirmed',
            organizer TEXT,
            remote_updated_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, source, external_id)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_calendar_events_tenant_window
        ON calendar_events (tenant_id, starts_at)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS calendar_events").run()
    }
}
