import FluentKit
import SQLKit

/// HER-290 — durable record of `(tenant_id, content_hash)` pairs the user
/// has rejected via memory review. `MemoryCompileService` consults this table
/// at the start of each compile run and skips `memory_upsert` calls whose
/// content hash matches a rejected entry — so the user isn't shown the
/// same "shall we learn this?" again across repeated runs.
///
/// `vault_file_id` is informational only (NULL when the source file has
/// already been deleted) — the dedup key is `(tenant_id, content_hash)`.
struct M54_CreateKBCompileRejectList: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(KBCompileRejectListEntry.schema)
            .id()
            .field("tenant_id", .uuid, .required,
                   .references(User.schema, "id", onDelete: .cascade))
            .field("content_hash", .string, .required)
            .field("vault_file_id", .uuid)
            .field("rejected_at", .datetime, .required)
            .unique(on: "tenant_id", "content_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(KBCompileRejectListEntry.schema).delete()
    }
}
