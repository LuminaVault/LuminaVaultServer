import FluentKit
import SQLKit

/// M79 — Google Calendar integration (HER-340).
///
/// `calendar_accounts`: one connected calendar provider per tenant. Holds
/// SecretBox-sealed OAuth refresh + access tokens and incremental-sync
/// bookkeeping (`sync_token`, rolling `window_*`). `attendees`/`recurrence`
/// on events are JSONB.
///
/// `calendar_events`: locally-cached events for schedule context + tool
/// queries, modeled on `health_events` (M14). Upsert key
/// `(tenant_id, source, external_id)` makes incremental sync idempotent;
/// indexed on `(tenant_id, starts_at)` for window queries.
struct M79_CreateCalendar: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M79Error.requiresSQL
        }

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS calendar_accounts (
            id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id          UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            provider           TEXT NOT NULL,
            account_email      TEXT NULL,
            scope              TEXT NOT NULL,
            refresh_ciphertext BYTEA NULL,
            refresh_nonce      BYTEA NULL,
            access_ciphertext  BYTEA NULL,
            access_nonce       BYTEA NULL,
            access_expires_at  TIMESTAMPTZ NULL,
            sync_token         TEXT NULL,
            last_synced_at     TIMESTAMPTZ NULL,
            window_start       TIMESTAMPTZ NULL,
            window_end         TIMESTAMPTZ NULL,
            status             TEXT NOT NULL DEFAULT 'connected',
            last_failure_at    TIMESTAMPTZ NULL,
            last_failure_code  TEXT NULL,
            created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, provider)
        )
        """#).run()

        try await sql.raw(#"""
        CREATE TABLE IF NOT EXISTS calendar_events (
            id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id         UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            source            TEXT NOT NULL,
            external_id       TEXT NOT NULL,
            calendar_id       TEXT NULL,
            title             TEXT NOT NULL,
            notes             TEXT NULL,
            location          TEXT NULL,
            starts_at         TIMESTAMPTZ NOT NULL,
            ends_at           TIMESTAMPTZ NOT NULL,
            all_day           BOOLEAN NOT NULL DEFAULT FALSE,
            status            TEXT NOT NULL DEFAULT 'confirmed',
            organizer         TEXT NULL,
            attendees         JSONB NULL,
            recurrence        JSONB NULL,
            html_link         TEXT NULL,
            etag              TEXT NULL,
            remote_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id, source, external_id)
        )
        """#).run()

        try await sql.raw(
            #"CREATE INDEX IF NOT EXISTS calendar_events_tenant_starts_idx ON calendar_events(tenant_id, starts_at)"#
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw M79Error.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS calendar_events").run()
        try await sql.raw("DROP TABLE IF EXISTS calendar_accounts").run()
    }
}

private enum M79Error: Error { case requiresSQL }
