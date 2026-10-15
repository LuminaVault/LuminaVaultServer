import Foundation

/// Picks the memories a chat turn is grounded on.
///
/// Chat used plain whole-memory vector search, top 5, and always used all
/// five: a question with nothing relevant in the vault still got five
/// unrelated memories pasted into its prompt. This uses the same hybrid search
/// as `/v1/query` and MCP (dense + lexical, chunk citations) and then drops
/// what is not close enough, so "nothing relevant" is a possible answer.
///
/// A hit is kept when it matched lexically — an exact hostname or error code
/// should ground the reply even if its embedding is far — or when its cosine
/// distance is within `maxDistance`.
struct ChatGrounding: Sendable {
    let memories: MemoryRepository
    let hybrid: HybridMemorySearch?
    let maxDistance: Float

    /// Cosine distance. Related text from the production embedder sits well
    /// under this; unrelated text sits above it. Configurable per deploy
    /// (`chat.retrieval.maxDistance`) because it depends on the embedder.
    static let defaultMaxDistance: Float = 0.6

    func retrieve(
        tenantID: UUID,
        query: String,
        queryEmbedding: [Float],
        limit: Int
    ) async throws -> [MemorySearchResult] {
        // Ask for more than we need: the floor removes some of them.
        let candidates: [MemorySearchResult] = if let hybrid {
            try await hybrid.search(
                tenantID: tenantID,
                query: query,
                queryEmbedding: queryEmbedding,
                limit: limit * 2
            )
        } else {
            try await memories.semanticSearch(tenantID: tenantID, queryEmbedding: queryEmbedding, limit: limit * 2)
        }
        return Array(Self.relevant(candidates, maxDistance: maxDistance).prefix(limit))
    }

    static func relevant(_ hits: [MemorySearchResult], maxDistance: Float) -> [MemorySearchResult] {
        hits.filter { ($0.lexicalScore ?? 0) > 0 || $0.distance <= maxDistance }
    }
}
