import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances + convenience

extension MemoryUpsertResponse: ResponseEncodable {}
extension MemorySearchResponse: ResponseEncodable {}
extension MemorySearchHitDTO: ResponseEncodable {}
extension MemoryListResponse: ResponseEncodable {}
extension MemoryLineageResponse: ResponseEncodable {}
extension MemoryLineageSourceDTO: ResponseEncodable {}
extension MemoryDTO: ResponseEncodable {}
extension MemoryGraphResponse: ResponseEncodable {}

// HER-207 — MemoryUpsertRequest now lives in LuminaVaultShared with the
// four optional geo fields. The server-local definition has been removed.

struct MemorySearchRequest: Codable {
    let query: String
    let limit: Int?
}

/// HER-200 L2 — non-throwing accessor for a Memory row that was fetched
/// from the DB. Fluent's `id` is structurally optional but any post-query
/// instance always has it set; this property asserts that invariant at
/// the type level so call sites stop wrapping every DTO mapping in `try`.
extension Memory {
    /// Returns the row's `id` for instances that have been persisted /
    /// fetched. Traps with a clear message when called on a pre-save
    /// model — that is a programmer error, not a runtime failure mode.
    var savedID: UUID {
        guard let id else {
            preconditionFailure("Memory.savedID called on unsaved Memory — use requireID() before persistence")
        }
        return id
    }
}

/// Server-only helper to create a MemoryDTO from a Fluent model. The
/// non-throwing path is the production default; callers operating on a
/// pre-save model should still go through `MemoryDTO.fromUnsavedMemory`.
extension MemoryDTO {
    /// Non-throwing converter for any Memory fetched from the DB. Uses
    /// `savedID` rather than `requireID()` so the call-site no longer has
    /// to wrap every DTO mapping in `try`.
    static func fromMemory(_ memory: Memory) -> MemoryDTO {
        MemoryDTO(
            id: memory.savedID,
            content: memory.content,
            tags: memory.tags ?? [],
            createdAt: memory.createdAt,
            lat: memory.lat,
            lng: memory.lng,
            accuracyM: memory.accuracyM,
            placeName: memory.placeName,
            reviewState: memory.reviewState,
        )
    }
}

/// Routes the user's authenticated requests through the Hermes tool-calling
/// agent (`HermesMemoryService`). Profile name == username; tenancy comes
/// from the JWT subject claim via `AppRequestContext.requireIdentity`.
///
/// HER-89 adds the user-facing CRUD surface (`GET /v1/memory`,
/// `DELETE /v1/memory/{id}`, `PATCH /v1/memory/{id}`) that bypasses the
/// agent loop and talks directly to the repository.
struct MemoryController {
    let service: HermesMemoryService
    let repository: MemoryRepository
    let embeddings: any EmbeddingService
    let achievements: AchievementsService?
    /// HER-235 — derives the read-only memory graph on request.
    let graphService: MemoryGraphService
    /// HER-290 — durable `(tenant_id, content_hash)` reject list used to dedup
    /// memories the user has already rejected.
    let rejectListRepository: KBCompileRejectListRepository

    private static let defaultLimit = 20
    private static let maxLimit = 100

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        addCaptureRoutes(to: router)
        addSearchRoutes(to: router)
        addReadRoutes(to: router)
    }

    func addAgentRoutes(to router: RouterGroup<AppRequestContext>) {
        addCaptureRoutes(to: router)
        addSearchRoutes(to: router)
    }

    func addCaptureRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/upsert", use: upsert)
    }

    func addSearchRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/search", use: search)
    }

    func addReadRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        // `/graph` is registered before `/:id` so Hummingbird's router takes
        // the static segment in preference to the UUID parameter match (HER-235).
        router.get("/graph", use: graph)
        router.get("/:id", use: getOne)
        router.get("/:id/lineage", use: lineage)
        router.delete("/:id", use: delete)
        router.patch("/:id", use: patch)
    }

    @Sendable
    func upsert(_ req: Request, ctx: AppRequestContext) async throws -> MemoryUpsertResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemoryUpsertRequest.self, context: ctx)
        guard !body.content.isEmpty else {
            throw HTTPError(.badRequest, message: "content required")
        }
        let tenantID = try user.requireID()
        let result = try await service.upsert(
            tenantID: tenantID,
            sessionKey: tenantID.uuidString,
            content: body.content,
        )
        // HER-207 — geo passthrough. The agent-driven upsert path doesn't
        // know about location, so we patch the four optional fields onto
        // the saved Memory after the tool call returns. All four are
        // independently optional; only fields actually supplied are set,
        // so a partial body (e.g. lat+lng without place_name) round-trips
        // correctly.
        let hasGeo = body.lat != nil || body.lng != nil || body.accuracyM != nil || body.placeName != nil
        if hasGeo {
            result.memory.lat = body.lat
            result.memory.lng = body.lng
            result.memory.accuracyM = body.accuracyM
            result.memory.placeName = body.placeName
            try await result.memory.save(on: repository.fluent.db())
        }
        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .memoryUpserted) }
        }
        return try MemoryUpsertResponse(
            memoryId: result.memory.requireID(),
            content: result.memory.content,
            summary: result.summary,
        )
    }

    @Sendable
    func search(_ req: Request, ctx: AppRequestContext) async throws -> MemorySearchResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemorySearchRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        let tenantID = try user.requireID()
        let answer = try await service.search(
            tenantID: tenantID,
            sessionKey: tenantID.uuidString,
            query: body.query,
            limit: body.limit ?? 5,
        )
        let hits = answer.hits.map {
            MemorySearchHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return MemorySearchResponse(hits: hits, summary: answer.summary)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> MemoryListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        if let space = req.uri.queryParameters["space"], !space.isEmpty {
            // Memory <-> Space binding lands with HER-105 (vault browser).
            // Surface this loudly instead of silently returning all memories.
            throw HTTPError(.notImplemented, message: "space filter awaits HER-105 space binding")
        }

        let limit = Self.clamp(
            req.uri.queryParameters["limit"].flatMap { Int($0) } ?? Self.defaultLimit,
            min: 1, max: Self.maxLimit,
        )
        let offset = max(0, req.uri.queryParameters["offset"].flatMap { Int($0) } ?? 0)
        let tag = req.uri.queryParameters["tag"].map { String($0) }

        // HER-290 — `reviewState` is comma-separated to keep the call-site
        // ergonomic (`?reviewState=pending,approved`). Empty / missing means
        // "all states except rejected" so the iOS list view doesn't show
        // user-rejected memories by default.
        let reviewStates: [String]?
        if let raw = req.uri.queryParameters["reviewState"], !raw.isEmpty {
            let parts = raw.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let known = Set(MemoryReviewState.all)
            let filtered = parts.filter { known.contains($0) }
            guard !filtered.isEmpty else {
                throw HTTPError(.badRequest, message: "reviewState must be a comma-separated subset of \(MemoryReviewState.all)")
            }
            reviewStates = filtered
        } else {
            reviewStates = nil
        }

        let rows = try await repository.listPaginated(
            tenantID: tenantID,
            tag: tag,
            reviewStates: reviewStates,
            limit: limit,
            offset: offset,
        )
        return MemoryListResponse(
            memories: rows.map(MemoryDTO.fromMemory),
            limit: limit,
            offset: offset,
        )
    }

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        guard let row = try await repository.find(tenantID: user.requireID(), id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        return MemoryDTO.fromMemory(row)
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let deleted = try await repository.delete(tenantID: user.requireID(), id: id)
        guard deleted else { throw HTTPError(.notFound, message: "memory not found") }
        return Response(status: .noContent)
    }

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let tenantID = try user.requireID()
        let body = try await req.decode(as: MemoryPatchRequest.self, context: ctx)

        guard body.content != nil || body.tags != nil || body.reviewState != nil else {
            throw HTTPError(.badRequest, message: "patch body must include content, tags, or reviewState")
        }

        if let content = body.content {
            guard !content.isEmpty else {
                throw HTTPError(.badRequest, message: "content cannot be empty")
            }
            let embedding = try await embeddings.embed(content, tenantID: tenantID)
            let updated = try await repository.updateContent(
                tenantID: tenantID, id: id, content: content, embedding: embedding,
            )
            guard updated else { throw HTTPError(.notFound, message: "memory not found") }
        }

        if let tags = body.tags {
            let updated = try await repository.updateTags(tenantID: tenantID, id: id, tags: tags)
            guard updated else { throw HTTPError(.notFound, message: "memory not found") }
        }

        // HER-290 — only `pending → approved` and `pending → rejected` are
        // legal transitions. Anything else is 422 so clients can't accidentally
        // un-reject a memory or stamp `auto` rows pending out-of-band.
        if let target = body.reviewState {
            guard let current = try await repository.find(tenantID: tenantID, id: id) else {
                throw HTTPError(.notFound, message: "memory not found")
            }
            let legal = current.reviewState == "pending"
                && (target == MemoryReviewState.approved || target == MemoryReviewState.rejected)
            guard legal else {
                throw HTTPError(
                    .unprocessableContent,
                    message: "reviewState transition \(current.reviewState) → \(target) not allowed",
                )
            }
            try await repository.updateReviewState(
                tenantID: tenantID,
                id: id,
                reviewState: target,
            )
            if target == MemoryReviewState.rejected {
                // Append `(tenant_id, content_hash)` so the next kb-compile
                // run skips re-learning the same content.
                try await rejectListRepository.record(
                    tenantID: tenantID,
                    contentHash: MemoryCompileService.contentHash(current.content),
                    vaultFileID: current.sourceVaultFileID,
                )
            }
        }

        guard let row = try await repository.find(tenantID: tenantID, id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        return MemoryDTO.fromMemory(row)
    }

    /// HER-150: Returns the source vault file (when known) the memory was
    /// derived from, plus a human-readable trace string. 404 when the
    /// memory doesn't exist or isn't owned by the caller.
    @Sendable
    func lineage(_: Request, ctx: AppRequestContext) async throws -> MemoryLineageResponse {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        guard let row = try await repository.findLineage(
            tenantID: user.requireID(),
            memoryID: id,
        ) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        let source: MemoryLineageSourceDTO?
        let trace: String
        if let sid = row.sourceVaultFileID, let path = row.sourcePath {
            source = MemoryLineageSourceDTO(
                vaultFileId: sid,
                path: path,
                createdAt: row.sourceCreatedAt,
            )
            let dateLabel = Self.formatTraceDate(row.sourceCreatedAt)
            trace = "Hermes learned this from your \(dateLabel) note at \(path)."
        } else {
            source = nil
            trace = "Hermes learned this directly — no source file recorded."
        }
        return MemoryLineageResponse(memoryId: row.memoryID, source: source, trace: trace)
    }

    /// HER-235 — returns the derived memory graph for the authenticated
    /// tenant. Nodes are top-scored memories; edges are computed on read
    /// from shared tags + pgvector cosine similarity. No persistence in v1.
    @Sendable
    func graph(_ req: Request, ctx: AppRequestContext) async throws -> MemoryGraphResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        let limit = Self.clamp(
            req.uri.queryParameters["limit"].flatMap { Int($0) } ?? MemoryGraphService.defaultLimit,
            min: 1, max: MemoryGraphService.maxLimit,
        )
        let similarity = Self.clampDouble(
            req.uri.queryParameters["similarityThreshold"].flatMap { Double($0) }
                ?? MemoryGraphService.defaultSimilarity,
            min: 0.0, max: 1.0,
        )
        let maxEdges = Self.clamp(
            req.uri.queryParameters["maxEdgesPerNode"].flatMap { Int($0) }
                ?? MemoryGraphService.defaultMaxEdgesPerNode,
            min: 1, max: MemoryGraphService.maxMaxEdgesPerNode,
        )

        return try await graphService.graph(
            tenantID: tenantID,
            limit: limit,
            similarity: similarity,
            maxEdgesPerNode: maxEdges,
        )
    }

    /// Renders a source date as "YYYY-MM-DD" UTC. Keeps the trace string
    /// stable across client locales — UI can re-format as it pleases.
    private static func formatTraceDate(_ date: Date?) -> String {
        guard let date else { return "earlier" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid memory id")
        }
        return id
    }

    private static func clamp(_ value: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, value))
    }

    private static func clampDouble(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, value))
    }
}
