import FluentKit
import SQLKit

/// HER-240a — `hermes_tenant_containers` table. One row per LuminaVault tenant
/// once that tenant has spawned (or had spawned for them) a personal Hermes
/// container. Tracks the container's docker name, host port, encrypted
/// `API_SERVER_KEY`, and the xai-oauth connect timestamp.
///
/// `tenant_id UNIQUE` enforces 1:1 tenant↔container. `api_server_key_*` is
/// sealed via the existing `SecretBox` HKDF/AES-GCM scheme; the raw key
/// never lives in the row.
struct M41_HermesTenantContainers: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS hermes_tenant_containers (
            id UUID PRIMARY KEY,
            tenant_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
            container_name TEXT NOT NULL UNIQUE,
            port INTEGER NOT NULL,
            api_server_key_ciphertext BYTEA NOT NULL,
            api_server_key_nonce BYTEA NOT NULL,
            xai_connected_at TIMESTAMPTZ,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            last_used_at TIMESTAMPTZ
        )
        """).run()

        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_hermes_tenant_containers_last_used_at
        ON hermes_tenant_containers (last_used_at)
        WHERE xai_connected_at IS NULL
        """).run()

        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_hermes_tenant_containers_port
        ON hermes_tenant_containers (port)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS hermes_tenant_containers").run()
    }
}
