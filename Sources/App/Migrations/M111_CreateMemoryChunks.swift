import FluentKit
import SQLKit

/// Heading-aware chunk index — the retrieval unit that carries a citation.
///
/// Until now a whole document was embedded as one vector (`VaultIngestService`
/// embedded the entire file into a single `memories` row), which made recall on
/// long notes poor and made citations impossible: a hit could say *which memory*
/// but never *which lines*. `memory_chunks` stores one row per
/// `MarkdownChunker` chunk, each with the locator (`source_path`,
/// `heading_path`, `start_line`, `end_line`) needed to point an answer back at
/// the exact source text.
///
/// `memories` stays the document-level row and remains the write target for
/// upserts; chunks are derived state, rebuilt from the raw vault file whenever
/// the document changes. Deleting every chunk and re-running the backfill is a
/// safe, lossless operation.
///
/// Both retrieval arms live on this table:
///   - `embedding` + HNSW for dense/semantic recall
///   - `content_tsv` + GIN for lexical recall (`websearch_to_tsquery`)
///
/// The lexical arm is the one `M39_HnswAndTsvector` promised on `memories` and
/// never wired up. Here it is queried from day one — see
/// `MemoryRepository.hybridSearch`.
///
/// Per-tenant partial HNSW indexes are created at runtime by
/// `TenantVectorIndexService.ensureChunkIndex(for:)`, for the same
/// `CREATE INDEX CONCURRENTLY` reason documented on `M39`.
struct M111_CreateMemoryChunks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
        CREATE TABLE IF NOT EXISTS memory_chunks (
            chunk_id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            tenant_id UUID NOT NULL,
            memory_id UUID NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            vault_file_id UUID REFERENCES vault_files(id) ON DELETE SET NULL,
            space_id UUID,
            source_path TEXT,
            ordinal INT NOT NULL,
            heading_path JSONB NOT NULL DEFAULT '[]'::jsonb,
            start_line INT NOT NULL,
            end_line INT NOT NULL,
            text TEXT NOT NULL,
            content_sha256 TEXT NOT NULL,
            embedding vector(1536),
            content_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """).run()

        // Re-chunking a document rewrites its rows; the ordinal is the identity
        // within a document, so a stale row can never survive a shorter rewrite.
        try await sql.raw("""
        CREATE UNIQUE INDEX IF NOT EXISTS memory_chunks_memory_ordinal_idx
        ON memory_chunks(memory_id, ordinal)
        """).run()

        // Tenant pre-filter for both search arms and for the delete-then-insert
        // rewrite path.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memory_chunks_tenant_memory_idx
        ON memory_chunks(tenant_id, memory_id)
        """).run()

        // Lets the backfill and the staleness check find a document's chunks by
        // the file they came from without touching `memories`.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memory_chunks_tenant_vault_file_idx
        ON memory_chunks(tenant_id, vault_file_id)
        """).run()

        // Lexical arm.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memory_chunks_content_tsv_idx
        ON memory_chunks USING gin (content_tsv)
        """).run()

        // Dense arm. Global fallback until a tenant gets its own partial index.
        try await sql.raw("""
        CREATE INDEX IF NOT EXISTS memory_chunks_embedding_hnsw_idx
        ON memory_chunks
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64)
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // Dropping the table drops its indexes with it.
        try await sql.raw("DROP TABLE IF EXISTS memory_chunks").run()
    }
}
