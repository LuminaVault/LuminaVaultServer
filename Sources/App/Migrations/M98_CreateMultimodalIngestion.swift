import FluentKit
import SQLKit

struct M98_CreateMultimodalIngestion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS ingestion_batches (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            space_id UUID REFERENCES spaces(id) ON DELETE SET NULL,
            state TEXT NOT NULL DEFAULT 'active',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS ingestion_items (
            id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            tenant_id UUID NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
            batch_id UUID NOT NULL REFERENCES ingestion_batches(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK (kind IN ('file', 'url')),
            state TEXT NOT NULL,
            file_name TEXT, content_type TEXT, size_bytes BIGINT,
            uploaded_bytes BIGINT NOT NULL DEFAULT 0, expected_sha256 TEXT, url TEXT,
            vault_file_id UUID REFERENCES vault_files(id) ON DELETE SET NULL,
            memory_id UUID REFERENCES memories(id) ON DELETE SET NULL,
            summary TEXT, error_message TEXT, credibility JSONB,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW())
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS ingestion_items_batch_idx ON ingestion_items(tenant_id, batch_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS ingestion_items_state_idx ON ingestion_items(state, updated_at)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS ingestion_items").run()
        try await sql.raw("DROP TABLE IF EXISTS ingestion_batches").run()
    }
}
