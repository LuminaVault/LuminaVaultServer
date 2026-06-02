import FluentKit
import SQLKit

/// Nous Subscription Integration — records when a tenant has connected their
/// own Nous Portal subscription via the OAuth device-code flow proxied into
/// their per-tenant Hermes container. Mirrors `xai_connected_at`: the real
/// credential (a refresh token) lives in `auth.json` on the container's
/// `/opt/data` volume, not in Postgres. When set, the container is exempt
/// from idle eviction so the user's `auth.json` is never reaped.
struct M70_AddNousConnectedAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "ALTER TABLE hermes_tenant_containers ADD COLUMN IF NOT EXISTS nous_connected_at TIMESTAMPTZ",
        ).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            "ALTER TABLE hermes_tenant_containers DROP COLUMN IF EXISTS nous_connected_at",
        ).run()
    }
}
