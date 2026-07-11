import FluentKit
import SQLKit

struct M103_AddIngestionSourceTokens: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS source_token_hash TEXT").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS source_token_expires_at TIMESTAMPTZ").run()
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS ingestion_items_source_token_idx
        ON ingestion_items(source_token_hash) WHERE source_token_hash IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS ingestion_items_source_token_idx").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS source_token_expires_at").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS source_token_hash").run()
    }
}
