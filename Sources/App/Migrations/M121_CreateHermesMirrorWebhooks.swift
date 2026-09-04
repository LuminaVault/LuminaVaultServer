import FluentKit
import SQLKit

/// Hermes Mirror Phase 2 — the optional inbound push credential, one per
/// tenant (M121).
///
/// The tenant's Hermes posts to `/v1/hermes/mirror/webhook/<token>` when a
/// cron job finishes, which only shortens the wait for the next collect; the
/// poll remains the source of truth, so losing this row costs latency and
/// nothing else.
///
/// `token` is the routing half and is unique globally — it is the only thing
/// in the URL, so two tenants must never share one. The signing secret is
/// sealed with the tenant's `SecretBox` key and is returned exactly once, by
/// the rotate route; it is never logged and never read back out to a client.
struct M121_CreateHermesMirrorWebhooks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await runMigrationScript(#"""
        CREATE TABLE IF NOT EXISTS hermes_mirror_webhooks (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            token TEXT NOT NULL,
            secret_ciphertext BYTEA NOT NULL,
            secret_nonce BYTEA NOT NULL,
            rotated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            UNIQUE (tenant_id),
            UNIQUE (token)
        );
        """#, on: sql)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS hermes_mirror_webhooks").run()
    }
}
