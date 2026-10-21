import FluentKit
import SQLKit

/// The opt-in pre-meeting brief.
///
/// - `apns_category_prefs.meeting_brief_enabled` is the opt-in. Unlike every
///   other column on that table it defaults to FALSE: a missing row, or a row
///   written before this column, means "off".
/// - `meeting_briefs` is one row per tenant per event. The primary key is the
///   claim: `MeetingBriefScheduler` inserts with `ON CONFLICT DO NOTHING`
///   before doing any work, and only the replica whose insert lands goes on to
///   embed, search and push. The row is kept whatever happens next (`outcome`:
///   `claimed`, `sent`, `empty`, `opted_out`, `no_device`, `failed`), so an
///   event with nothing to say is not re-searched on every tick of its
///   25–35 minute window. `memories` is what the push promised, as
///   `[{"id": uuid, "similarity": 0…1}]`, nearest first; the brief endpoint
///   reads it back so the sheet matches the push without a second embedding.
///
/// Attendees need no schema change: `calendar_events.attendees` (JSONB, M79)
/// has been there since the Google sync, which already fills it.
struct M148_CreateMeetingBriefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        ALTER TABLE apns_category_prefs
            ADD COLUMN IF NOT EXISTS meeting_brief_enabled BOOLEAN NOT NULL DEFAULT FALSE
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS meeting_briefs (
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            event_id UUID NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
            claimed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            sent_at TIMESTAMPTZ NULL,
            outcome TEXT NOT NULL DEFAULT 'claimed',
            memories JSONB NOT NULL DEFAULT '[]'::jsonb,
            PRIMARY KEY (tenant_id, event_id)
        )
        """).run()
        // The scheduler's window scan only ever looks at opted-in tenants.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS apns_category_prefs_meeting_brief_idx
            ON apns_category_prefs (tenant_id) WHERE meeting_brief_enabled
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS meeting_briefs").run()
        try await sql.raw("DROP INDEX IF EXISTS apns_category_prefs_meeting_brief_idx").run()
        try await sql.raw("ALTER TABLE apns_category_prefs DROP COLUMN IF EXISTS meeting_brief_enabled").run()
    }
}

private enum MigrationError: Error { case requiresSQL }
