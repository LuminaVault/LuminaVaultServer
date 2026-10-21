import Algorithms
import Foundation
import Logging

/// The retrieval entry point: chunk-level hybrid search unioned with the
/// legacy document-level semantic search.
///
/// Two arms, on purpose:
///
/// - **Chunk arm** (`MemoryChunkRepository.hybridSearch`) — dense + lexical RRF
///   over `memory_chunks`. Carries a `MemoryCitation`, so anything it returns
///   can be pointed at a file, heading, and line range.
/// - **Document arm** (`MemoryRepository.semanticSearch`) — the pre-existing
///   whole-memory pgvector search. No citation.
///
/// Keeping the document arm is not just migration scaffolding. It is what makes
/// chunk indexing safe to fail: a memory whose chunks are missing (backfill has
/// not reached it, embedding provider errored during ingest, or it never had a
/// source file) is still retrievable. Results are deduplicated by memory id
/// with the chunk hit winning, so a document never appears twice and the
/// citation-bearing version is always preferred.
struct HybridMemorySearch: Sendable {
    let memories: MemoryRepository
    let chunks: MemoryChunkRepository
    let logger: Logger

    /// Search both arms and merge.
    ///
    /// - Parameter query: the raw user text, used by the lexical arm.
    /// - Parameter queryEmbedding: its vector, used by both dense paths. Nil
    ///   when the provider could not embed the query (`embedForQuery`): both
    ///   arms then search lexically, so an embedding outage costs ranking
    ///   quality instead of failing the request.
    /// - Parameter countHits: `false` for lookups that are not recall (the
    ///   pre-meeting brief), so they leave `query_hit_count` alone. Only the
    ///   document arm counts hits; the chunk arm is read-only either way.
    func search(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float]?,
        limit: Int,
        spaceID: UUID? = nil,
        countHits: Bool = true
    ) async throws -> [MemorySearchResult] {
        async let chunkHits = chunkArm(
            tenantID: tenantID,
            query: query,
            queryEmbedding: queryEmbedding,
            limit: limit,
            spaceID: spaceID
        )
        async let documentHits = memories.searchDocuments(
            tenantID: tenantID,
            query: query,
            queryEmbedding: queryEmbedding,
            limit: limit,
            spaceID: spaceID,
            countHits: countHits
        )

        return try await Self.merge(chunks: chunkHits, documents: documentHits, limit: limit)
    }

    /// The chunk arm degraded to empty on failure.
    ///
    /// A broken chunk query must not take down search entirely — the document
    /// arm alone is exactly today's behavior, which is a working product.
    private func chunkArm(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float]?,
        limit: Int,
        spaceID: UUID?
    ) async -> [MemorySearchResult] {
        do {
            return try await chunks.hybridSearch(
                tenantID: tenantID,
                query: query,
                queryEmbedding: queryEmbedding,
                limit: limit,
                spaceID: spaceID
            )
        } catch {
            logger.error("memory.search.chunkArmFailed tenant=\(tenantID): \(error)")
            return []
        }
    }

    /// Deduplicate by memory id, preferring the citation-bearing hit.
    ///
    /// Chunk hits are kept in their fused order; document hits only fill the
    /// remaining slots. A document hit for a memory already represented by a
    /// chunk is dropped — it is the same content with less precision.
    static func merge(
        chunks: [MemorySearchResult],
        documents: [MemorySearchResult],
        limit: Int
    ) -> [MemorySearchResult] {
        // Lazy, so it stops reading as soon as `limit` unique hits are found.
        Array(chain(chunks, documents).lazy.uniqued(on: \.id).prefix(limit))
    }
}
