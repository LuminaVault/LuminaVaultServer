import FluentKit
import SQLKit

struct M104_CompleteMultimodalIngestion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS content_sha256 TEXT").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS pipeline_version TEXT NOT NULL DEFAULT 'multimodal-v2'").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS reused_from_item_id UUID REFERENCES ingestion_items(id) ON DELETE SET NULL").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS graph_ready_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS terminal_notified_at TIMESTAMPTZ").run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS ingestion_items_dedup_idx
        ON ingestion_items (tenant_id, content_sha256, pipeline_version)
        WHERE state = 'completed' AND content_sha256 IS NOT NULL
        """).run()
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS ingestion_events (
            id BIGSERIAL PRIMARY KEY,
            tenant_id UUID NOT NULL,
            batch_id UUID NOT NULL REFERENCES ingestion_batches(id) ON DELETE CASCADE,
            item_id UUID REFERENCES ingestion_items(id) ON DELETE CASCADE,
            type TEXT NOT NULL,
            state TEXT,
            uploaded_bytes BIGINT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS ingestion_events_batch_idx ON ingestion_events (tenant_id, batch_id, id)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP TABLE IF EXISTS ingestion_events").run()
        try await sql.raw("DROP INDEX IF EXISTS ingestion_items_dedup_idx").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS terminal_notified_at").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS graph_ready_at").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS reused_from_item_id").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS pipeline_version").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS content_sha256").run()
    }
}
