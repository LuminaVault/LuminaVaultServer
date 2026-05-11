import FluentKit
import SQLKit

/// HER-147 — adds the scoring + access-tracking columns the monthly
/// pruning job needs to decide what's worth keeping. All additive,
/// `IF NOT EXISTS`, safe to re-run.
///
/// Columns:
/// - `score FLOAT NOT NULL DEFAULT 0` — cached value of the scoring
///   function so prune queries don't recompute on every sweep.
/// - `access_count BIGINT NOT NULL DEFAULT 0` — direct reads / opens.
/// - `query_hit_count BIGINT NOT NULL DEFAULT 0` — semantic-search hits.
/// - `last_accessed_at TIMESTAMPTZ NULL` — wall-clock of most recent
///   access; feeds the recency term in the score.
///
/// Index `(tenant_id, score)` makes the prune predicate
/// `WHERE tenant_id = $1 AND score < $2 AND created_at < $3` a single
/// index-served scan.
struct M21_AddMemoryScore: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw(
            #"ALTER TABLE memories ADD COLUMN IF NOT EXISTS score DOUBLE PRECISION NOT NULL DEFAULT 0"#
        ).run()
        try await sql.raw(
            #"ALTER TABLE memories ADD COLUMN IF NOT EXISTS access_count BIGINT NOT NULL DEFAULT 0"#
        ).run()
        try await sql.raw(
            #"ALTER TABLE memories ADD COLUMN IF NOT EXISTS query_hit_count BIGINT NOT NULL DEFAULT 0"#
        ).run()
        try await sql.raw(
            #"ALTER TABLE memories ADD COLUMN IF NOT EXISTS last_accessed_at TIMESTAMPTZ"#
        ).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_memories_tenant_score
            ON memories (tenant_id, score)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_tenant_score").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS last_accessed_at").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS query_hit_count").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS access_count").run()
        try await sql.raw("ALTER TABLE memories DROP COLUMN IF EXISTS score").run()
    }
}
