import FluentKit
import SQLKit

/// Adds `tags TEXT[]` to `memories` plus a GIN index so `WHERE 'foo' = ANY(tags)`
/// and `tags && ARRAY['foo','bar']` are index-served. Backs HER-89
/// (list/delete/tag endpoints) and HER-151 (auto-tagging service).
struct M18_AddMemoryTags: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE memories ADD COLUMN IF NOT EXISTS tags TEXT[]").run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_memories_tags
            ON memories
            USING GIN (tags)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_tags").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS tags").run()
    }
}
