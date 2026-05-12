import FluentKit
import SQLKit

/// M30 — billing_events table for RevenueCat webhook idempotency.
///
/// Each inbound webhook payload is logged as a row keyed on
/// `provider_event_id` (RevenueCat's `event.id`). Before processing,
/// the handler checks for an existing row — replay-safe.
struct M30_CreateBillingEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M30Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS billing_events (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            provider_event_id TEXT NOT NULL,
            provider        TEXT NOT NULL DEFAULT 'revenuecat',
            event_type      TEXT NOT NULL,
            user_id         UUID REFERENCES users(id) ON DELETE SET NULL,
            raw_payload     TEXT NOT NULL,
            processed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
            created_at      TIMESTAMPTZ DEFAULT now(),
            CONSTRAINT billing_events_provider_event_id_key UNIQUE (provider_event_id)
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS billing_events_user_id_idx ON billing_events(user_id)"#,
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M30Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS billing_events").run()
    }
}

private enum M30Error: Error { case requiresSQL }
