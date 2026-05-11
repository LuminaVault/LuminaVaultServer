import FluentKit
import SQLKit

struct M13_CreateVaultFile: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Self-sufficient: ensure pg_trgm exists even if M00 was applied
        // before the extension addition was added there.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE EXTENSION IF NOT EXISTS \"pg_trgm\"").run()
        }
        try await database.schema(VaultFile.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("space_id", .uuid,
                   .references(Space.schema, "id", onDelete: .setNull))
            .field("path", .string, .required)
            .field("content_type", .string, .required)
            .field("size_bytes", .int64, .required)
            .field("sha256", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "path")
            .create()

        // Trigram index for fuzzy `path LIKE '%foo%'` lookup; falls back to
        // seqscan gracefully if pg_trgm isn't available (it is — see M00).
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_vault_files_path_trgm
            ON vault_files USING gin (path gin_trgm_ops)
            """).run()
            try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_vault_files_tenant_created
            ON vault_files (tenant_id, created_at DESC)
            """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(VaultFile.schema).delete()
    }
}
