import Foundation
import Logging

/// What a caller does when the embedding provider fails after its own retry
/// and fallback chain: carry on without a vector rather than fail the request.
///
/// Until real embeddings (#292) the deterministic stub could not fail, so
/// every capture path quietly depended on `embed` succeeding. With a real
/// provider an outage or an empty balance (OpenRouter's 402) turned
/// `POST /v1/memory/upsert` into a 500 and lost the user's note. A note saved
/// without a vector is still listed, still found by the lexical arm of search,
/// and gets its vector from the heal pass in `EmbeddingReembedService` once the
/// provider answers again; a note that was never saved is gone.
///
/// Cancellation still propagates: a request or shutdown that was cancelled
/// must not be reported as a degraded save.
extension EmbeddingService {
    /// Embed `text` for a write path. Returns nil — and logs why — when the
    /// provider fails, so the caller persists the row with `embedding = NULL`.
    ///
    /// - Parameter operation: names the write path in the log line
    ///   (`memory.upsert`, `vault.upload`, …).
    func embedForWrite(
        _ text: String,
        tenantID: UUID,
        operation: String,
        logger: Logger = EmbeddingDegradation.logger
    ) async throws -> [Float]? {
        do {
            return try await embed(text, tenantID: tenantID)
        } catch {
            try EmbeddingDegradation.rethrowIfCancelled(error)
            logger.warning(
                "embedding.degraded op=\(operation) tenant=\(tenantID): saved without an embedding, the heal pass fills it in later. \(error)"
            )
            return nil
        }
    }

    /// Embed the user's query for search. Returns nil — and logs why — when
    /// the provider fails, so the caller runs a lexical-only search instead
    /// of failing the request.
    func embedForQuery(
        _ query: String,
        tenantID: UUID,
        operation: String,
        logger: Logger = EmbeddingDegradation.logger
    ) async throws -> [Float]? {
        do {
            return try await embed(query, tenantID: tenantID)
        } catch {
            try EmbeddingDegradation.rethrowIfCancelled(error)
            logger.warning(
                "embedding.degraded op=\(operation) tenant=\(tenantID): query not embedded, searching lexically. \(error)"
            )
            return nil
        }
    }

    /// `embedBatch` for a write path: nil for every text when the batch fails.
    /// One failed chunk fails the batch (see `embedBatch`), and a provider
    /// that refused one chunk has almost always refused them all.
    func embedBatchForWrite(
        _ texts: [String],
        tenantID: UUID,
        operation: String,
        logger: Logger = EmbeddingDegradation.logger
    ) async throws -> [[Float]?] {
        do {
            return try await embedBatch(texts, tenantID: tenantID)
        } catch {
            try EmbeddingDegradation.rethrowIfCancelled(error)
            logger.warning(
                "embedding.degraded op=\(operation) tenant=\(tenantID) texts=\(texts.count): saved without embeddings, the heal pass fills them in later. \(error)"
            )
            return Array(repeating: nil, count: texts.count)
        }
    }
}

enum EmbeddingDegradation {
    static let logger = Logger(label: "lv.embedding.degraded")

    /// URLSession reports a cancelled request as a network error rather than
    /// a `CancellationError`, so check the task too.
    static func rethrowIfCancelled(_ error: any Error) throws {
        if error is CancellationError {
            throw error
        }
        try Task.checkCancellation()
    }
}
