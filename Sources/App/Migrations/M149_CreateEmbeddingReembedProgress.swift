import FluentKit
import SQLKit

/// Cursor table for `EmbeddingReembedService`, the one-shot job that rewrites
/// every stored text embedding after the provider changes (production ran on
/// the deterministic hash stub, so every stored vector is noise).
///
/// One row per target table (`memories`, `memory_chunks`, `memories_archive`).
/// `last_id` is the primary key of the last row the job finished, as text —
/// `memories.id` is a UUID but `memory_chunks.chunk_id` is TEXT, and the job
/// casts it back per target. The row is written after every batch, so a
/// restart resumes after the last finished batch. `completed_at` set means the
/// target is done and the job never looks at it again; deleting the row
/// re-runs it from the start. `rows_failed` counts rows whose embed call
/// failed and so still carry their old vector.
struct M149_CreateEmbeddingReembedProgress: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS embedding_reembed_progress (
            target TEXT PRIMARY KEY,
            last_id TEXT NULL,
            rows_done BIGINT NOT NULL DEFAULT 0,
            rows_failed BIGINT NOT NULL DEFAULT 0,
            completed_at TIMESTAMPTZ NULL,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw MigrationError.requiresSQL
        }
        try await sql.raw("DROP TABLE IF EXISTS embedding_reembed_progress").run()
    }
}

private enum MigrationError: Error { case requiresSQL }
