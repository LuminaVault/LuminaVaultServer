import Foundation

/// HER-134 — per-tenant embedding contract. The tenant-aware overload feeds
/// the monthly token cost-guard (`EmbeddingUsageTracker`) and lets fallback
/// providers attribute spend correctly. The legacy zero-arg call funnels
/// through the same path under a sentinel tenant so existing callers keep
/// compiling while we thread tenantID upstream.
protocol EmbeddingService: Sendable {
    /// Returns embedding vector for given text. 1536 dims (column-pinned).
    func embed(_ text: String, tenantID: UUID) async throws -> [Float]
}

extension EmbeddingService {
    /// Sentinel tenant for legacy call sites that have not yet threaded a
    /// real tenantID. Cost-guard treats this as "unattributed" (counts
    /// against a global bucket so we still see runaway spend).
    static var unattributedTenantID: UUID {
        UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    func embed(_ text: String) async throws -> [Float] {
        try await embed(text, tenantID: Self.unattributedTenantID)
    }
}

/// Deterministic dev/test embedder. Replace via `EMBEDDING_PROVIDER=openai`
/// (or `hermesLocal`, `nomic`) in prod. Kept in tests for hermetic specs.
struct DeterministicEmbeddingService: EmbeddingService {
    func embed(_ text: String, tenantID _: UUID) async throws -> [Float] {
        var v = [Float](repeating: 0, count: 1536)
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return v }
        for i in 0 ..< v.count {
            let b = bytes[i % bytes.count]
            v[i] = (Float(b) / 127.5) - 1.0
        }
        return v
    }
}
