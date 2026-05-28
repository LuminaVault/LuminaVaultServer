import FluentKit

/// HER-134 — monthly token-usage counter, one row per
/// `(tenant_id, year_month)`. Backs the embedding cost guard.
/// `year_month` is `"YYYY-MM"` (UTC). Composite unique enforces upsert
/// semantics; tokens_used is a running sum across the month.
struct M56_CreateEmbeddingUsage: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(EmbeddingUsage.schema)
            .id()
            .field("tenant_id", .uuid, .required)
            .field("year_month", .string, .required)
            .field("tokens_used", .int64, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "tenant_id", "year_month")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EmbeddingUsage.schema).delete()
    }
}
