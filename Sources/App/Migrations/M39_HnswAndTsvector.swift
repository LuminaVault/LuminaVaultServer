import FluentKit
import SQLKit

/// HER-234 — vector database optimisation scaffold.
///
/// Three additive changes:
///   1. Replace the global `idx_memories_embedding` IVFFlat index with an
///      HNSW index (cosine ops, `m=16`, `ef_construction=64`). HNSW gives
///      better recall at MVP scale and removes the `lists` tuning pain.
///   2. Add a `STORED` generated `content_tsv` tsvector column populated by
///      `to_tsvector('english', content)` plus a GIN index. The column lights
///      up hybrid search in a follow-up ticket — the query rewrite is *not*
///      part of this migration.
///   3. Leave the existing `idx_memories_tenant_created` composite index
///      untouched (still used by the planner for the tenant pre-filter).
///
/// Per-tenant partial HNSW indexes are created at runtime by
/// `TenantVectorIndexService.ensureIndex(for:)` because they require
/// `CREATE INDEX CONCURRENTLY`, which Postgres refuses inside the
/// transaction Fluent's migrator wraps `prepare(on:)` in.
struct M39_HnswAndTsvector: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        // 1. Generated tsvector column + GIN index. Idempotent.
        try await sql.raw("""
        ALTER TABLE memories
        ADD COLUMN IF NOT EXISTS content_tsv tsvector
        GENERATED ALWAYS AS (to_tsvector('english', content)) STORED
        """).run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_memories_content_tsv
        ON memories USING gin (content_tsv)
        """).run()

        // 2. Swap IVFFlat → HNSW. Drop first so a re-run after a failed
        //    HNSW create cleans the half-built state.
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_embedding").run()
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_memories_embedding_hnsw
        ON memories
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_embedding_hnsw").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_content_tsv").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS content_tsv").run()
        // Restore the IVFFlat index that M07 originally created so a
        // forward-roll-back-forward cycle ends in the same place it started.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS idx_memories_embedding
        ON memories
        USING ivfflat (embedding vector_cosine_ops)
        WITH (lists = 100)
        """).run()
    }
}
