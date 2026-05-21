import FluentKit
import SQLKit

/// HER-179 — per-tenant APNS category opt-out. One row per user; defaults
/// all true so the absence of a row means "all push categories allowed".
/// `APNSNotificationService` checks this table before dispatch and
/// no-ops if the relevant category is disabled.
struct M43_CreateApnsCategoryPrefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS apns_category_prefs (
            tenant_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            chat_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            nudge_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            digest_enabled BOOLEAN NOT NULL DEFAULT TRUE,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS apns_category_prefs").run()
    }
}
