import FluentKit
import SQLKit

struct M07_AddMemoryEmbedding: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // 1536 dims = OpenAI text-embedding-3-small. Adjust if model changes.
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS embedding vector(1536)").run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_memories_embedding
        ON memories
        USING ivfflat (embedding vector_cosine_ops)
        WITH (lists = 100)
        """).run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_memories_tenant_created ON memories (tenant_id, created_at DESC)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_embedding").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_tenant_created").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS embedding").run()
    }
}
