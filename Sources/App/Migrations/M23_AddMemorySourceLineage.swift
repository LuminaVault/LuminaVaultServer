import FluentKit
import SQLKit

/// HER-150: Memory lineage tracker. Each `memory_upsert` may optionally
/// declare the `vault_files` row it was derived from. `ON DELETE SET NULL`
/// keeps the memory alive when the source file is soft-deleted; the trace
/// just degrades to "source unknown" rather than cascading the deletion.
///
/// Indexed on `source_vault_file_id` so reverse lookups ("show me every
/// memory that came from this note") are cheap.
struct M23_AddMemorySourceLineage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE memories
            ADD COLUMN IF NOT EXISTS source_vault_file_id UUID
            REFERENCES vault_files(id) ON DELETE SET NULL
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_memories_source_vault_file
            ON memories (source_vault_file_id)
            WHERE source_vault_file_id IS NOT NULL
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_source_vault_file").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS source_vault_file_id").run()
    }
}
