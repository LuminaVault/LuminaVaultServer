import Foundation

protocol EmbeddingService: Sendable {
    /// Returns embedding vector for given text. 1536 dims (OpenAI text-embedding-3-small).
    func embed(_ text: String) async throws -> [Float]
}

/// Deterministic dev/test embedder. Replace with OpenAI / local model in a follow-up phase.
struct DeterministicEmbeddingService: EmbeddingService {
    func embed(_ text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: 1536)
        let bytes = Array(text.utf8)
        if bytes.isEmpty { return v }
        for i in 0..<v.count {
            let b = bytes[i % bytes.count]
            v[i] = (Float(b) / 127.5) - 1.0
        }
        return v
    }
}
