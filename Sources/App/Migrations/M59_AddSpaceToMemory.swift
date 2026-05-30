import FluentKit
import SQLKit

/// HER-105 — bind memories to Spaces. Adds a nullable `space_id` FK to
/// `memories` so captured text/photo notes can be filed into the same
/// Spaces the vault browser already uses for files. NULL = unfiled.
///
/// `ON DELETE SET NULL` mirrors the lineage FK (M23): deleting a Space
/// must not cascade-delete the memories filed under it — they just drop
/// back to "unfiled". Partial index on `(tenant_id, space_id)` keeps the
/// per-Space list probe cheap without bloating the index for unfiled rows.
struct M59_AddSpaceToMemory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Memory.schema)
            .field("space_id", .uuid, .references(Space.schema, "id", onDelete: .setNull))
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_memories_tenant_space
        ON memories (tenant_id, space_id)
        WHERE space_id IS NOT NULL
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try? await sql.raw("DROP INDEX IF EXISTS idx_memories_tenant_space").run()
        }
        try await database.schema(Memory.schema)
            .deleteField("space_id")
            .update()
    }
}
