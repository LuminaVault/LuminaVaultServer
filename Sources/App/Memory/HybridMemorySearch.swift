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
    /// - Parameter queryEmbedding: its vector, used by both dense paths.
    func search(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float],
        limit: Int,
        spaceID: UUID? = nil
    ) async throws -> [MemorySearchResult] {
        async let chunkHits = chunkArm(
            tenantID: tenantID,
            query: query,
            queryEmbedding: queryEmbedding,
            limit: limit,
            spaceID: spaceID
        )
        async let documentHits = memories.semanticSearch(
            tenantID: tenantID,
            queryEmbedding: queryEmbedding,
            limit: limit,
            spaceID: spaceID
        )

        return Self.merge(chunks: await chunkHits, documents: try await documentHits, limit: limit)
    }

    /// The chunk arm degraded to empty on failure.
    ///
    /// A broken chunk query must not take down search entirely — the document
    /// arm alone is exactly today's behavior, which is a working product.
    private func chunkArm(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float],
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
        var seen = Set<UUID>()
        var merged: [MemorySearchResult] = []
        merged.reserveCapacity(limit)

        for hit in chunks where seen.insert(hit.id).inserted {
            merged.append(hit)
            if merged.count == limit { return merged }
        }
        for hit in documents where seen.insert(hit.id).inserted {
            merged.append(hit)
            if merged.count == limit { return merged }
        }
        return merged
    }
}
