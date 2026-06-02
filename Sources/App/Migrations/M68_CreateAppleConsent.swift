import FluentKit
import SQLKit

/// Apple Ecosystem Integration P0 — per-tenant, per-domain data-access consent.
/// `allowed` gates on-device sync AND Hermes tool access for the domain;
/// `allow_writes` lets Hermes make changes (Calendar/Reminders). Rows are
/// created lazily on first PUT; absent row = not allowed.
struct M68_CreateAppleConsent: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS apple_consent (
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            domain TEXT NOT NULL,
            allowed BOOLEAN NOT NULL DEFAULT FALSE,
            allow_writes BOOLEAN NOT NULL DEFAULT FALSE,
            last_sync_at TIMESTAMPTZ,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (tenant_id, domain)
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS apple_consent").run()
    }
}
