import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared
import SQLKit

/// Read and write access to `memory_chunks` — the retrieval unit that carries
/// a citation.
///
/// Every statement here is raw SQL for the same reason `MemoryRepository`'s
/// vector paths are: Fluent has no native `vector` type, and `content_tsv` is a
/// generated column Fluent must never try to write. That means the tenant row
/// filter is *not* inherited from `TenantModel` — **every query in this file
/// must bind `tenant_id` explicitly**, and `MemoryChunkIsolationTests` exists to
/// keep that honest.
struct MemoryChunkRepository {
    let fluent: Fluent
    var telemetry: RouteTelemetry?

    /// Reciprocal Rank Fusion constant. 60 is the value from the original
    /// Cormack et al. paper and the de-facto default; it damps the influence of
    /// the top rank enough that one arm cannot dominate the other.
    private static let rrfK = 60

    /// How deep each arm reaches before fusion. Wider than `limit` so a result
    /// ranked poorly by one arm can still be rescued by the other.
    private static let armDepthMultiplier = 4

    // MARK: - Write

    /// Replace every chunk for a memory with a freshly computed set.
    ///
    /// Delete-then-insert inside one transaction: a re-chunk that produces
    /// fewer chunks than before must not leave orphaned high-ordinal rows
    /// behind, and a partially rewritten document must never be searchable.
    ///
    /// `embeddings` is positional — index `i` is the vector for `chunks[i]`.
    /// A count mismatch is a programming error and throws rather than silently
    /// storing chunks with no vector.
    func replaceChunks(
        tenantID: UUID,
        memoryID: UUID,
        documentID: String,
        vaultFileID: UUID?,
        spaceID: UUID?,
        sourcePath: String?,
        chunks: [DocumentChunk],
        embeddings: [[Float]]
    ) async throws {
        guard chunks.count == embeddings.count else {
            throw HTTPError(.internalServerError, message: "chunk/embedding count mismatch")
        }
        try await fluent.db().transaction { db in
            guard let tx = db as? any SQLDatabase else {
                throw HTTPError(.internalServerError, message: "SQL driver required for chunk write")
            }
            try await tx.raw("""
            DELETE FROM memory_chunks
            WHERE tenant_id = \(bind: tenantID) AND memory_id = \(bind: memoryID)
            """).run()

            for (index, chunk) in chunks.enumerated() {
                let chunkID = ChunkIDs.chunkID(
                    documentID: documentID,
                    ordinal: chunk.ordinal,
                    contentSHA256: chunk.contentSHA256
                )
                let vector = MemoryRepository.formatVector(embeddings[index])
                let headingPathJSON = Self.encodeHeadingPath(chunk.headingPath)

                try await tx.raw("""
                INSERT INTO memory_chunks (
                    chunk_id, document_id, tenant_id, memory_id, vault_file_id, space_id,
                    source_path, ordinal, heading_path, start_line, end_line, text,
                    content_sha256, embedding, created_at
                ) VALUES (
                    \(bind: chunkID), \(bind: documentID), \(bind: tenantID), \(bind: memoryID),
                    \(bind: vaultFileID), \(bind: spaceID), \(bind: sourcePath), \(bind: chunk.ordinal),
                    \(bind: headingPathJSON)::jsonb, \(bind: chunk.startLine), \(bind: chunk.endLine),
                    \(bind: chunk.text), \(bind: chunk.contentSHA256),
                    \(unsafeRaw: "'\(vector)'::vector"), NOW()
                )
                ON CONFLICT (chunk_id) DO NOTHING
                """).run()
            }
        }
    }

    /// Drop every chunk for a memory. Called when the memory itself is deleted
    /// through a path that bypasses the FK cascade (soft deletes, tag-only
    /// rewrites that invalidate chunk text).
    func deleteChunks(tenantID: UUID, memoryID: UUID) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for chunk delete")
        }
        try await sql.raw("""
        DELETE FROM memory_chunks
        WHERE tenant_id = \(bind: tenantID) AND memory_id = \(bind: memoryID)
        """).run()
    }

    // MARK: - Read

    /// True when this tenant has at least one chunk.
    ///
    /// The hybrid search path uses this to decide whether to fall back to
    /// whole-memory semantic search: a tenant whose backfill has not run yet
    /// must keep getting the old (worse, but working) results rather than an
    /// empty page.
    func hasChunks(tenantID: UUID) async throws -> Bool {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for chunk probe")
        }
        let rows = try await sql.raw("""
        SELECT 1 AS present FROM memory_chunks WHERE tenant_id = \(bind: tenantID) LIMIT 1
        """).all(decoding: ChunkPresenceRow.self)
        return !rows.isEmpty
    }

    /// Hybrid retrieval: dense pgvector recall fused with lexical tsquery recall.
    ///
    /// Dense search alone misses exact tokens — a hostname, an error code, a
    /// UUID, a person's name — because those carry little semantic signal.
    /// Lexical search alone misses paraphrase. Reciprocal Rank Fusion takes both
    /// rankings and sums `1/(k + rank)` per arm, so a result that either arm
    /// ranks highly surfaces without either arm's score scale mattering.
    ///
    /// `websearch_to_tsquery` is deliberate: unlike `to_tsquery` it cannot raise
    /// a syntax error on user input, so `AND`, quotes, parentheses and stray
    /// operators in a real question degrade to plain terms instead of a 500.
    ///
    /// Read-only. No hit-count bump, no analytics insert — see
    /// `MemoryRepository.semanticSearch` for the side-effecting variant.
    func hybridSearch(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float],
        limit: Int,
        spaceID: UUID? = nil
    ) async throws -> [MemorySearchResult] {
        if let telemetry {
            return try await telemetry.observe("memory.hybridSearch") {
                try await hybridSearchRaw(
                    tenantID: tenantID,
                    query: query,
                    queryEmbedding: queryEmbedding,
                    limit: limit,
                    spaceID: spaceID
                )
            }
        }
        return try await hybridSearchRaw(
            tenantID: tenantID,
            query: query,
            queryEmbedding: queryEmbedding,
            limit: limit,
            spaceID: spaceID
        )
    }

    private func hybridSearchRaw(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float],
        limit: Int,
        spaceID: UUID?
    ) async throws -> [MemorySearchResult] {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for hybrid search")
        }
        let limit = max(1, limit)
        let depth = limit * Self.armDepthMultiplier
        let vector = MemoryRepository.formatVector(queryEmbedding)
        let distance = "embedding <=> '\(vector)'::vector"

        let rows = try await sql.raw("""
        WITH tsq AS (
            SELECT websearch_to_tsquery('english', \(bind: query)) AS query
        ),
        dense AS (
            SELECT chunk_id,
                   ROW_NUMBER() OVER (ORDER BY \(unsafeRaw: distance) ASC) AS rank,
                   \(unsafeRaw: distance) AS distance
            FROM memory_chunks
            WHERE tenant_id = \(bind: tenantID)
              AND (\(bind: spaceID) IS NULL OR space_id = \(bind: spaceID))
              AND embedding IS NOT NULL
            ORDER BY \(unsafeRaw: distance) ASC
            LIMIT \(bind: depth)
        ),
        lexical AS (
            SELECT c.chunk_id,
                   ROW_NUMBER() OVER (ORDER BY ts_rank_cd(c.content_tsv, tsq.query) DESC) AS rank,
                   ts_rank_cd(c.content_tsv, tsq.query) AS score
            FROM memory_chunks c
            CROSS JOIN tsq
            WHERE c.tenant_id = \(bind: tenantID)
              AND (\(bind: spaceID) IS NULL OR c.space_id = \(bind: spaceID))
              AND c.content_tsv @@ tsq.query
            ORDER BY ts_rank_cd(c.content_tsv, tsq.query) DESC
            LIMIT \(bind: depth)
        ),
        fused AS (
            SELECT COALESCE(d.chunk_id, l.chunk_id) AS chunk_id,
                   COALESCE(1.0 / (\(bind: Self.rrfK) + d.rank), 0)
                 + COALESCE(1.0 / (\(bind: Self.rrfK) + l.rank), 0) AS rrf,
                   d.distance AS distance,
                   l.score AS lexical_score
            FROM dense d
            FULL OUTER JOIN lexical l ON d.chunk_id = l.chunk_id
        )
        SELECT c.chunk_id,
               c.document_id,
               c.memory_id,
               c.tenant_id,
               c.source_path,
               c.heading_path::text AS heading_path_json,
               c.start_line,
               c.end_line,
               c.text,
               c.created_at,
               m.origin_kind,
               m.origin_provider,
               m.origin_model,
               f.rrf,
               f.distance,
               f.lexical_score,
               ts_headline('english', c.text, tsq.query,
                           'MaxFragments=2, MinWords=8, MaxWords=32, StartSel=[, StopSel=]') AS snippet
        FROM fused f
        JOIN memory_chunks c ON c.chunk_id = f.chunk_id
        JOIN memories m ON m.id = c.memory_id
        CROSS JOIN tsq
        WHERE c.tenant_id = \(bind: tenantID)
          AND m.tenant_id = \(bind: tenantID)
          AND m.review_state <> \(bind: MemoryReviewState.rejected)
        ORDER BY f.rrf DESC, f.distance ASC NULLS LAST
        LIMIT \(bind: limit)
        """).all(decoding: ChunkSearchRow.self)

        return rows.map { row in
            MemorySearchResult(
                id: row.memory_id,
                tenantID: row.tenant_id,
                content: row.text,
                createdAt: row.created_at,
                // Dense distance is absent when only the lexical arm matched.
                // 1.0 is "maximally far" on the cosine scale, which is the
                // honest reading: this hit was earned lexically, not semantically.
                distance: row.distance.map(Float.init) ?? 1.0,
                source: MemorySourceKindDTO(rawValue: row.origin_kind) ?? .legacy,
                provider: row.origin_provider,
                model: row.origin_model,
                snippet: row.snippet,
                citation: MemoryCitation(
                    chunkID: row.chunk_id,
                    documentID: row.document_id,
                    path: row.source_path,
                    headingPath: Self.decodeHeadingPath(row.heading_path_json),
                    startLine: row.start_line,
                    endLine: row.end_line
                )
            )
        }
    }

    // MARK: - Heading path coding

    /// `heading_path` is JSONB so Postgres validates it; we hand it a JSON array
    /// string and read it back the same way rather than relying on a driver
    /// mapping for a column type Fluent does not model.
    static func encodeHeadingPath(_ path: [String]) -> String {
        guard let data = try? JSONEncoder().encode(path),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    static func decodeHeadingPath(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}

private struct ChunkPresenceRow: Decodable {
    let present: Int
}

private struct ChunkSearchRow: Decodable {
    let chunk_id: String
    let document_id: String
    let memory_id: UUID
    let tenant_id: UUID
    let source_path: String?
    let heading_path_json: String?
    let start_line: Int
    let end_line: Int
    let text: String
    let created_at: Date?
    let origin_kind: String
    let origin_provider: String?
    let origin_model: String?
    let rrf: Double?
    let distance: Double?
    let lexical_score: Double?
    let snippet: String?
}
