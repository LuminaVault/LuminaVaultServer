import FluentKit
import SQLKit

/// "Feed Your Brain" — bulk import session + per-item tracking. `import_sessions`
/// is the batch; `import_items` are the individual links/files staged into the
/// vault and (once approved) filed into Spaces. Both cascade-delete with the
/// owning tenant; items cascade with their session.
struct M61_CreateImportSessions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ImportSession.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("source_type", .string, .required)
            .field("status", .string, .required)
            .field("total_items", .int, .required, .sql(.default(0)))
            .field("staged_items", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await database.schema(ImportItem.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("session_id", .uuid, .required,
                   .references(ImportSession.schema, "id", onDelete: .cascade))
            .field("vault_file_id", .uuid)
            .field("url", .string)
            .field("title", .string)
            .field("proposed_space", .string)
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_import_items_session
        ON import_items (session_id)
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try? await sql.raw("DROP INDEX IF EXISTS idx_import_items_session").run()
        }
        try await database.schema(ImportItem.schema).delete()
        try await database.schema(ImportSession.schema).delete()
    }
}
