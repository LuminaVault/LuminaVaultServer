import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension AppleSyncResponse: @retroactive ResponseEncodable {}

/// Apple Photos derived-text index (M81).
///
///   POST /v1/photos/index — batch ingest derived OCR text + scene tags + meta
///
/// PRIVACY-CRITICAL: only derived text + metadata cross the wire — never
/// pixels. Consent-gated on `AppleDataDomain.photos`; revoking the domain
/// purges the server copy (`AppleConsentController.purgeDomain`).
///
/// Each item is embedded (via the shared `EmbeddingService`, 1536 dims) and
/// upserted by `(tenant_id, asset_local_id)`. The pgvector handling mirrors
/// `MemoryRepository` exactly — Fluent has no native vector encoder, so the
/// `embedding` column is spliced as a raw SQL literal while everything else is
/// parameter-bound.
struct PhotoIndexController {
    let fluent: HummingbirdFluent.Fluent
    let embeddings: any EmbeddingService
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/index", use: index)
    }

    @Sendable
    func index(_ req: Request, ctx: AppRequestContext) async throws -> AppleSyncResponse {
        let tenantID = try ctx.requireIdentity().requireID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }
        let (allowed, _) = await AppleConsentController.isAllowed(tenantID: tenantID, domain: .photos, sql: sql)
        guard allowed else {
            throw HTTPError(.forbidden, message: "photos access not allowed by the user")
        }

        let body = try await req.decode(as: PhotoIndexSyncRequest.self, context: ctx)

        var inserted = 0
        var updated = 0
        var skipped = 0

        for item in body.items {
            let assetID = item.assetLocalID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !assetID.isEmpty else { skipped += 1; continue }

            // Embed OCR text when present; otherwise store NULL embedding (the
            // row is still recallable by metadata/scene-tag filters, just not
            // by semantic search). Scene tags reinforce the OCR signal in the
            // embedding so a tag-only screenshot ("receipt") is still findable.
            let embedSource = Self.embedSource(ocr: item.ocrText, tags: item.sceneTags)
            var vectorLiteral = "NULL"
            if let embedSource {
                let vec = try await embeddings.embed(embedSource, tenantID: tenantID)
                vectorLiteral = "'\(MemoryRepository.formatVector(vec))'::vector"
            }

            let tagsLiteral: String = {
                guard let tags = item.sceneTags, !tags.isEmpty else { return "NULL" }
                return MemoryRepository.formatTextArray(tags)
            }()

            let outcome = try await sql.raw("""
            INSERT INTO photo_index
                (id, tenant_id, asset_local_id, taken_at, is_screenshot, ocr_text, scene_tags, embedding, created_at, updated_at)
            VALUES
                (\(bind: UUID()), \(bind: tenantID), \(bind: assetID), \(bind: item.takenAt),
                 \(bind: item.isScreenshot), \(bind: item.ocrText),
                 \(unsafeRaw: tagsLiteral), \(unsafeRaw: vectorLiteral), NOW(), NOW())
            ON CONFLICT (tenant_id, asset_local_id) DO UPDATE
              SET taken_at = EXCLUDED.taken_at,
                  is_screenshot = EXCLUDED.is_screenshot,
                  ocr_text = EXCLUDED.ocr_text,
                  scene_tags = EXCLUDED.scene_tags,
                  embedding = EXCLUDED.embedding,
                  updated_at = NOW()
            RETURNING (xmax = 0) AS was_inserted
            """).first(decoding: UpsertRow.self)

            if outcome?.was_inserted == true { inserted += 1 } else { updated += 1 }
        }

        logger.info("photos.index tenant=\(tenantID) inserted=\(inserted) updated=\(updated) skipped=\(skipped)")
        return AppleSyncResponse(inserted: inserted, updated: updated, skipped: skipped)
    }

    /// Combines OCR text + scene tags into the text we embed. Returns nil when
    /// there is nothing meaningful to embed (so the row gets a NULL vector).
    static func embedSource(ocr: String?, tags: [String]?) -> String? {
        let ocrTrimmed = ocr?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tagsJoined = (tags ?? []).joined(separator: ", ")
        var parts: [String] = []
        if !ocrTrimmed.isEmpty { parts.append(ocrTrimmed) }
        if !tagsJoined.isEmpty { parts.append("Scene: \(tagsJoined)") }
        let combined = parts.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    /// Cosine semantic search over a tenant's photo index. Consent is gated by
    /// the caller (SkillRunner). Mirrors `MemoryRepository.semanticSearch`:
    /// tenant filter BEFORE order-by so the planner can pre-filter, then the
    /// HNSW cosine index serves the ordering.
    static func semanticSearch(
        tenantID: UUID,
        queryEmbedding: [Float],
        limit: Int,
        sql: any SQLDatabase,
    ) async throws -> [PhotoSearchHit] {
        let vec = MemoryRepository.formatVector(queryEmbedding)
        let rows = try await sql.raw("""
        SELECT asset_local_id, taken_at, is_screenshot, ocr_text, scene_tags,
               embedding <=> \(unsafeRaw: "'\(vec)'::vector") AS distance
        FROM photo_index
        WHERE tenant_id = \(bind: tenantID)
          AND embedding IS NOT NULL
        ORDER BY distance ASC
        LIMIT \(bind: limit)
        """).all(decoding: PhotoSearchRow.self)
        return rows.map {
            PhotoSearchHit(
                takenAt: $0.taken_at,
                isScreenshot: $0.is_screenshot,
                ocrText: $0.ocr_text,
                sceneTags: $0.scene_tags ?? [],
                // Cosine distance ∈ [0,2]; expose a 0–1 similarity score.
                score: max(0, 1 - ($0.distance / 2)),
            )
        }
    }

    /// True when the tenant has at least one indexed photo (used to decide
    /// whether semantic search can answer, or the tool should fall back to a
    /// live device fetch).
    static func hasRows(tenantID: UUID, sql: any SQLDatabase) async -> Bool {
        struct CountRow: Decodable { let n: Int }
        let row = try? await sql.raw("""
        SELECT COUNT(*)::int AS n FROM photo_index WHERE tenant_id = \(bind: tenantID)
        """).first(decoding: CountRow.self)
        return (row?.n ?? 0) > 0
    }
}

private struct UpsertRow: Decodable {
    let was_inserted: Bool
}

private struct PhotoSearchRow: Decodable {
    let asset_local_id: String
    let taken_at: Date?
    let is_screenshot: Bool
    let ocr_text: String?
    let scene_tags: [String]?
    let distance: Float
}

/// Internal search result (server-only; not a wire DTO). Serialised to the
/// `photos_search` tool's JSON contract in `SkillRunner`.
struct PhotoSearchHit: Sendable {
    let takenAt: Date?
    let isScreenshot: Bool
    let ocrText: String?
    let sceneTags: [String]
    let score: Float
}
