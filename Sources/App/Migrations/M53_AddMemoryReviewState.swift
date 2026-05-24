import FluentKit
import SQLKit

/// HER-290 — moderation state on `memories`. Backfill defaults existing rows
/// to `"auto"` so manual upserts + pre-HER-290 captures stay visible; only
/// new memories produced by kb-compile flip to `"pending"` going forward.
///
/// Partial index on `(tenant_id) WHERE review_state = 'pending'` keeps the
/// "needs review" probe cheap without bloating the index for the common
/// approved/auto rows.
struct M53_AddMemoryReviewState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Memory.schema)
            .field("review_state", .string, .required, .sql(.default("auto")))
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memories_pending_review_per_tenant
        ON memories (tenant_id)
        WHERE review_state = 'pending'
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try? await sql.raw("DROP INDEX IF EXISTS memories_pending_review_per_tenant").run()
        }
        try await database.schema(Memory.schema)
            .deleteField("review_state")
            .update()
    }
}
