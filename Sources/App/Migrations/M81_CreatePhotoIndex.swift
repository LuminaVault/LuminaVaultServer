import FluentKit
import SQLKit

/// Apple Photos derived-text index. Stores OCR text + on-device scene tags +
/// metadata for screenshots/photos so Hermes can semantically recall them
/// ("the screenshot about the flight"). PRIVACY: never pixels — only derived
/// text + metadata. `embedding` mirrors the memories pgvector setup (M07/M39):
/// raw `vector(1536)` column with a cosine HNSW index.
///
/// Upsert key is `(tenant_id, asset_local_id)` — the PHAsset localIdentifier —
/// so client deltas are idempotent. FK cascades on tenant delete; revoking the
/// `.photos` consent domain purges rows via `AppleConsentController.purgeDomain`.
struct M81_CreatePhotoIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS photo_index (
            id uuid PRIMARY KEY,
            tenant_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            asset_local_id text NOT NULL,
            taken_at timestamptz,
            is_screenshot boolean NOT NULL DEFAULT false,
            ocr_text text,
            scene_tags text[],
            embedding vector(1536),
            created_at timestamptz NOT NULL DEFAULT NOW(),
            updated_at timestamptz NOT NULL DEFAULT NOW()
        )
        """).run()

        // Idempotent upsert key.
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_photo_index_tenant_asset
        ON photo_index (tenant_id, asset_local_id)
        """).run()

        // Tenant pre-filter for the semantic-search planner (mirrors
        // idx_memories_tenant_created).
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_photo_index_tenant_taken
        ON photo_index (tenant_id, taken_at DESC)
        """).run()

        // Cosine HNSW index — same style as memories' idx_memories_embedding_hnsw
        // (M39). m=16, ef_construction=64.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_photo_index_embedding_hnsw
        ON photo_index
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_photo_index_embedding_hnsw").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_photo_index_tenant_taken").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_photo_index_tenant_asset").run()
        try await sql.raw("DROP TABLE IF EXISTS photo_index").run()
    }
}
