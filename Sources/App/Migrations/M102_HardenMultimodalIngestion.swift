import FluentKit
import SQLKit

struct M102_HardenMultimodalIngestion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS next_attempt_at TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE ingestion_items ADD COLUMN IF NOT EXISTS lease_expires_at TIMESTAMPTZ").run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS ingestion_items_claim_idx
        ON ingestion_items(state, next_attempt_at, created_at)
        WHERE state = 'queued'
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS ingestion_items_claim_idx").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS lease_expires_at").run()
        try await sql.raw("ALTER TABLE ingestion_items DROP COLUMN IF EXISTS next_attempt_at").run()
    }
}
