import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import NIOCore
import SQLKit

/// HER-205 — coordinates the active vision-embed adapter, pads/truncates
/// the embedding to the pgvector dim, and (optionally) writes the result
/// to `memories.embedding` when the caller passes
/// `?indexAs=memory&memoryId=<uuid>`. Sits between `VisionEmbedController`
/// (HTTP boundary) and `VisionEmbedProviderAdapter` (upstream).
struct VisionEmbedService: Sendable {
    let registry: VisionEmbedProviderRegistry
    let fluent: Fluent
    let usageMeter: UsageMeterService?
    let logger: Logger
    /// Target dim — MUST match the `vector(N)` column on `memories.embedding`.
    /// HER-205 acceptance: pgvector ANN search works directly with the
    /// returned vector, so this has to match the existing schema (1536).
    let targetDim: Int

    func embed(
        image: ByteBuffer,
        mime: String,
        tenantID: UUID,
        indexAsMemory: UUID?,
    ) async throws -> VisionEmbedResponse {
        guard let adapter = await registry.active() else {
            logger.error("no active vision embed provider — check vision.embed.provider env knob")
            throw HTTPError(.serviceUnavailable, message: "vision embed provider not configured")
        }

        let result: VisionEmbedUpstreamResult
        do {
            result = try await adapter.embed(image: image, mime: mime)
        } catch let providerError as VisionEmbedProviderError {
            logger.error("vision embed provider error: \(providerError)")
            switch providerError {
            case .permanent:
                throw HTTPError(.badGateway, message: "vision embed upstream rejected request")
            case .transient, .network, .decode:
                throw HTTPError(.badGateway, message: "vision embed upstream unavailable")
            }
        }

        let normalized = Self.padOrTruncate(result.embedding, to: targetDim)

        // Optional ANN index write — keeps the controller's `?indexAs=memory`
        // contract atomic with the embedding call so iOS doesn't have to
        // round-trip a second request.
        if let memoryID = indexAsMemory {
            try await writeEmbedding(tenantID: tenantID, memoryID: memoryID, embedding: normalized)
        }

        // Best-effort fire-and-forget usage row. Image embeds are billed
        // per-call by Cohere/OpenAI; we record 1 "call" as a constant
        // tokens-equivalent so STT/chat/vision land in the same table.
        if let usageMeter {
            let kind = await registry.activeKindResolved()
            let meter = usageMeter
            let modelToRecord = "vision.embed:\(kind.rawValue)"
            Task { await meter.record(tenantID: tenantID, model: modelToRecord, tokensIn: 1, tokensOut: 0) }
        }

        return VisionEmbedResponse(
            embedding: normalized,
            dim: targetDim,
            model: result.model,
            sourceWidth: result.sourceWidth ?? 0,
            sourceHeight: result.sourceHeight ?? 0,
        )
    }

    /// Zero-pad or right-truncate the provider embedding to the pgvector
    /// column width. Zero-padding is safe under cosine similarity when the
    /// vectors are L2-normalized (added zeros do not change angular
    /// distance). Truncation drops trailing dims; the provider model
    /// determines how harmful that is — note in the TODO if we adopt a
    /// model wider than 1536.
    static func padOrTruncate(_ v: [Float], to dim: Int) -> [Float] {
        if v.count == dim { return v }
        if v.count > dim { return Array(v.prefix(dim)) }
        return v + Array(repeating: 0, count: dim - v.count)
    }

    /// Writes a vector to `memories.embedding` for the given `(tenant, id)`
    /// without touching `content` — the embedding came from an image, not
    /// from the memory text, and we don't want to invalidate the text body.
    private func writeEmbedding(tenantID: UUID, memoryID: UUID, embedding: [Float]) async throws {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for vector update")
        }
        let vec = MemoryRepository.formatVector(embedding)
        let rows = try await sql.raw("""
        UPDATE memories
        SET embedding = \(unsafeRaw: "'\(vec)'::vector")
        WHERE tenant_id = \(bind: tenantID) AND id = \(bind: memoryID)
        RETURNING id
        """).all(decoding: VisionEmbedIndexedRow.self)
        if rows.isEmpty {
            throw HTTPError(.notFound, message: "memory not found for tenant")
        }
    }
}

private struct VisionEmbedIndexedRow: Decodable {
    let id: UUID
}
