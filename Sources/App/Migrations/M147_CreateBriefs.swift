import FluentKit
import SQLKit

/// The daily brief as cards (`briefs`) and what the user thought of them
/// (`brief_feedback`).
///
/// - `briefs` holds one row per tenant per local day (`date` is the day on
///   the user's clock, `users.timezone`). `BriefComposer` upserts on
///   `(tenant_id, date)`, so re-running the daily-brief skill the same day
///   replaces the cards and keeps the brief's id.
/// - `brief_feedback` is one row per card per brief: a second tap replaces
///   the first (`ON CONFLICT (brief_id, card_id) DO UPDATE`), so tapping 👎
///   twice is not twice as loud. `card_kind` is copied so ranking by kind
///   over the last 14 days needs no JSON digging.
struct M147_CreateBriefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS briefs (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            date DATE NOT NULL,
            cards JSONB NOT NULL DEFAULT '[]'::jsonb,
            end_note TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (tenant_id, date)
        )
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS brief_feedback (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            brief_id UUID NOT NULL REFERENCES briefs(id) ON DELETE CASCADE,
            card_id TEXT NOT NULL,
            card_kind TEXT NOT NULL,
            action TEXT NOT NULL CHECK (action IN ('up', 'down', 'dismiss')),
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (brief_id, card_id)
        )
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS brief_feedback_tenant_created
        ON brief_feedback (tenant_id, created_at DESC)
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("brief_feedback").delete()
        try await database.schema("briefs").delete()
    }
}

private enum MigrationError: Error { case requiresSQL }
