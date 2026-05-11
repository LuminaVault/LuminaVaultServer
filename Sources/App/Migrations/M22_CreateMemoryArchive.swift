import FluentKit
import SQLKit

/// HER-147 — `memories_archive`: cold storage for memories pruned by the
/// monthly job. Mirrors the `memories` schema 1:1 (minus the IVFFlat
/// vector index — archived rows are not semantic-searched) plus an
/// `archived_at` column so we can reason about pruning cadence.
///
/// Pruning is a `INSERT INTO memories_archive ... SELECT FROM memories;
/// DELETE FROM memories ...` — never a hard DELETE. Archive rows still
/// FK CASCADE on `users(id)` so account deletion (HER-92) wipes them too.
struct M22_CreateMemoryArchive: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // Same shape as `memories` plus `archived_at`. Vector column kept
        // so we can revive a row by INSERT'ing back into `memories`
        // without re-embedding.
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS memories_archive (
                id UUID PRIMARY KEY,
                tenant_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                content TEXT NOT NULL,
                tags TEXT[],
                embedding vector(1536),
                score DOUBLE PRECISION NOT NULL DEFAULT 0,
                access_count BIGINT NOT NULL DEFAULT 0,
                query_hit_count BIGINT NOT NULL DEFAULT 0,
                last_accessed_at TIMESTAMPTZ,
                created_at TIMESTAMPTZ,
                archived_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_memories_archive_tenant_archived
            ON memories_archive (tenant_id, archived_at DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_memories_archive_tenant_archived").run()
        try await sql.raw("DROP TABLE IF EXISTS memories_archive").run()
    }
}
