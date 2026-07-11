import FluentKit
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances + convenience

extension MemoryUpsertResponse: @retroactive ResponseEncodable {}
extension MemorySearchResponse: @retroactive ResponseEncodable {}
extension MemorySearchHitDTO: @retroactive ResponseEncodable {}
extension MemoryListResponse: @retroactive ResponseEncodable {}
extension MemoryLineageResponse: @retroactive ResponseEncodable {}
extension MemoryLineageSourceDTO: @retroactive ResponseEncodable {}
extension MemoryDTO: @retroactive ResponseEncodable {}
extension MemoryGraphResponse: @retroactive ResponseEncodable {}
extension MemoryProvenanceResponse: @retroactive ResponseEncodable {}
extension MemoryFacetsResponse: @retroactive ResponseEncodable {}

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
    static func fromMemory(
        _ memory: Memory,
        provenance: MemoryProvenanceSummaryDTO? = nil
    ) -> MemoryDTO {
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
            provenance: provenance ?? memory.originSummary,
            createdByUserId: memory.createdByUserID,
            updatedByUserId: memory.updatedByUserID
        )
    }
}

extension Memory {
    var originSummary: MemoryProvenanceSummaryDTO? {
        let source = MemorySourceKindDTO(rawValue: originKind) ?? .legacy
        let actor: MemoryActorKindDTO = originProvider == nil ? (source == .manual ? .user : .system) : .model
        let model = originProvider.flatMap { provider in
            originModel.map { ModelProvenanceDTO(provider: provider, model: $0) }
        }
        let contribution = MemoryContributionDTO(
            id: savedID,
            operation: .create,
            actor: actor,
            source: source,
            model: model,
            sourceReference: originSourceID,
            createdAt: createdAt ?? .distantPast
        )
        return MemoryProvenanceSummaryDTO(
            createdBy: contribution,
            contributors: model.map { [$0] } ?? []
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
    let vaultAccess: VaultAccessService
    let service: HermesMemoryService
    let repository: MemoryRepository
    let embeddings: any EmbeddingService
    let achievements: AchievementsWorker?
    /// HER-235 — derives the read-only memory graph on request.
    let graphService: MemoryGraphService
    /// HER-290 — durable `(tenant_id, content_hash)` reject list used to dedup
    /// memories the user has already rejected.
    let rejectListRepository: KBCompileRejectListRepository
    var provenanceRepository: MemoryProvenanceRepository {
        MemoryProvenanceRepository(fluent: repository.fluent)
    }

    /// HER-171 — fires `SkillEvent.memoryUpserted` so the skills runtime can
    /// react to a freshly-saved memory. Optional: test wirings can omit it.
    var eventBus: EventBus?

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
        router.get("/facets", use: facets)
        router.get("/:id", use: getOne)
        router.get("/:id/lineage", use: lineage)
        router.get("/:id/provenance", use: provenance)
        router.delete("/:id", use: delete)
        router.patch("/:id", use: patch)
    }

    @Sendable
    func upsert(_ req: Request, ctx: AppRequestContext) async throws -> MemoryUpsertResponse {
        _ = try ctx.requireIdentity()
        let body = try await req.decode(as: MemoryUpsertRequest.self, context: ctx)
        let content = body.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw HTTPError(.badRequest, message: "content required")
        }
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID

        // HER-105 — optional Space target via `?space_id=` query param (mirrors
        // `POST /v1/vault/files`). The shared `MemoryUpsertRequest` DTO is a
        // pinned package so the binding rides the query string instead of a new
        // body field. Validated against the caller's Spaces (cross-tenant /
        // malformed id → 400).
        let spaceID = try await resolveOptionalSpaceID(
            req.uri.queryParameters["space_id"].map(String.init),
            tenantID: tenantID
        )

        // Deterministic save: embed + persist directly. The capture path must
        // NOT depend on an LLM choosing to call a `memory_upsert` tool — that
        // path routed through the capability table to Gemini, which frequently
        // replied in plain text and never emitted the tool call, 502-ing every
        // text/photo capture ("hermes did not call memory_upsert"). Saving a
        // note is mechanical (embed + insert); the agent loop only added
        // latency and a failure mode.
        let embedding = try await embeddings.embed(content, tenantID: tenantID)
        let memory = try await repository.create(
            tenantID: tenantID,
            content: content,
            embedding: embedding,
            spaceID: spaceID,
            contribution: .user(.create)
        )
        let actorID = try ctx.requireTenantID()
        memory.createdByUserID = actorID
        memory.updatedByUserID = actorID
        try await memory.update(on: repository.fluent.db())

        // HER-207 — geo passthrough. All four fields are independently
        // optional; only those actually supplied are set, so a partial body
        // (e.g. lat+lng without place_name) round-trips correctly.
        let hasGeo = body.lat != nil || body.lng != nil || body.accuracyM != nil || body.placeName != nil
        if hasGeo {
            memory.lat = body.lat
            memory.lng = body.lng
            memory.accuracyM = body.accuracyM
            memory.placeName = body.placeName
            try await memory.save(on: repository.fluent.db())
        }

        let memoryID = try memory.requireID()

        // HER-171 — notify the skills runtime a memory landed (best-effort;
        // never blocks or fails the save).
        if let eventBus {
            eventBus.publish(SkillEvent(
                type: .memoryUpserted,
                tenantID: tenantID,
                payload: [SkillEvent.PayloadKey.memoryID: memoryID.uuidString]
            ))
        }
        if let achievements {
            achievements.enqueue(tenantID: tenantID, event: .memoryUpserted)
        }

        return MemoryUpsertResponse(
            memoryId: memoryID,
            content: memory.content,
            summary: "Saved to your vault."
        )
    }

    /// HER-105 — validates an optional `space_id` query param and confirms it
    /// belongs to `tenantID`. nil-in / nil-out is the unfiled path; a malformed
    /// UUID or cross-tenant id raises 400 so the client sees the
    /// misconfiguration instead of the memory silently landing unfiled.
    private func resolveOptionalSpaceID(_ raw: String?, tenantID: UUID) async throws -> UUID? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let spaceID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "`space_id` is not a valid UUID")
        }
        let exists = try await Space.query(on: repository.fluent.db(), tenantID: tenantID)
            .filter(\.$id == spaceID)
            .first()
        guard exists != nil else {
            throw HTTPError(.badRequest, message: "`space_id` does not belong to the caller")
        }
        return spaceID
    }

    @Sendable
    func search(_ req: Request, ctx: AppRequestContext) async throws -> MemorySearchResponse {
        let body = try await req.decode(as: MemorySearchRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .ai).vaultID
        let answer = try await service.search(
            tenantID: tenantID,
            sessionKey: tenantID.uuidString,
            query: body.query,
            limit: body.limit ?? 5
        )
        let hits = answer.hits.map {
            MemorySearchHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return MemorySearchResponse(hits: hits, summary: answer.summary)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> MemoryListResponse {
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID

        if let space = req.uri.queryParameters["space"], !space.isEmpty {
            // Memory <-> Space binding lands with HER-105 (vault browser).
            // Surface this loudly instead of silently returning all memories.
            throw HTTPError(.notImplemented, message: "space filter awaits HER-105 space binding")
        }

        let limit = Self.clamp(
            req.uri.queryParameters["limit"].flatMap { Int($0) } ?? Self.defaultLimit,
            min: 1, max: Self.maxLimit
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
            offset: offset
        )
        let summaries = try await provenanceRepository.summaries(
            tenantID: tenantID,
            memoryIDs: rows.map(\.savedID)
        )
        return MemoryListResponse(
            memories: rows.map { MemoryDTO.fromMemory($0, provenance: summaries[$0.savedID]) },
            limit: limit,
            offset: offset
        )
    }

    @Sendable
    func getOne(_ req: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID
        let id = try Self.parseID(ctx)
        guard let row = try await repository.find(tenantID: tenantID, id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        row.updatedByUserID = try ctx.requireTenantID()
        try await row.update(on: repository.fluent.db())
        let summary = try await provenanceRepository.summaries(
            tenantID: tenantID,
            memoryIDs: [row.savedID]
        )[row.savedID]
        return MemoryDTO.fromMemory(row, provenance: summary)
    }

    @Sendable
    func delete(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let id = try Self.parseID(ctx)
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
        if let memory = try await repository.find(tenantID: tenantID, id: id) {
            try await provenanceRepository.suppressJob(tenantID: tenantID, memory: memory)
        }
        let deleted = try await repository.delete(tenantID: tenantID, id: id)
        guard deleted else { throw HTTPError(.notFound, message: "memory not found") }
        return Response(status: .noContent)
    }

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let id = try Self.parseID(ctx)
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write).vaultID
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
                tenantID: tenantID,
                id: id,
                content: content,
                embedding: embedding,
                contribution: .user(.update)
            )
            guard updated else { throw HTTPError(.notFound, message: "memory not found") }
        }

        if let tags = body.tags {
            let updated = try await repository.updateTags(
                tenantID: tenantID,
                id: id,
                tags: tags,
                contribution: body.content == nil ? .user(.update) : nil
            )
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
                    message: "reviewState transition \(current.reviewState) → \(target) not allowed"
                )
            }
            try await repository.updateReviewState(
                tenantID: tenantID,
                id: id,
                reviewState: target
            )
            if body.content == nil, body.tags == nil {
                try await provenanceRepository.record(
                    tenantID: tenantID,
                    memoryID: id,
                    input: .user(.update)
                )
            }
            if target == MemoryReviewState.rejected {
                // Append `(tenant_id, content_hash)` so the next kb-compile
                // run skips re-learning the same content.
                try await rejectListRepository.record(
                    tenantID: tenantID,
                    contentHash: MemoryCompileService.contentHash(current.content),
                    vaultFileID: current.sourceVaultFileID
                )
            }
        }

        guard let row = try await repository.find(tenantID: tenantID, id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        let summary = try await provenanceRepository.summaries(
            tenantID: tenantID,
            memoryIDs: [row.savedID]
        )[row.savedID]
        return MemoryDTO.fromMemory(row, provenance: summary)
    }

    @Sendable
    func provenance(_ req: Request, ctx: AppRequestContext) async throws -> MemoryProvenanceResponse {
        let memoryID = try Self.parseID(ctx)
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID
        guard let response = try await provenanceRepository.timeline(
            tenantID: tenantID,
            memoryID: memoryID
        ) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        return response
    }

    @Sendable
    func facets(_ req: Request, ctx: AppRequestContext) async throws -> MemoryFacetsResponse {
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID
        return try await provenanceRepository.facets(tenantID: tenantID)
    }

    /// HER-150: Returns the source vault file (when known) the memory was
    /// derived from, plus a human-readable trace string. 404 when the
    /// memory doesn't exist or isn't owned by the caller.
    @Sendable
    func lineage(_ req: Request, ctx: AppRequestContext) async throws -> MemoryLineageResponse {
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID
        let id = try Self.parseID(ctx)
        guard let row = try await repository.findLineage(
            tenantID: tenantID,
            memoryID: id
        ) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        let source: MemoryLineageSourceDTO?
        let trace: String
        if let sid = row.sourceVaultFileID, let path = row.sourcePath {
            source = MemoryLineageSourceDTO(
                vaultFileId: sid,
                path: path,
                createdAt: row.sourceCreatedAt
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
        let tenantID = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read).vaultID

        let limit = Self.clamp(
            req.uri.queryParameters["limit"].flatMap { Int($0) } ?? MemoryGraphService.defaultLimit,
            min: 1, max: MemoryGraphService.maxLimit
        )
        let similarity = Self.clampDouble(
            req.uri.queryParameters["similarityThreshold"].flatMap { Double($0) }
                ?? MemoryGraphService.defaultSimilarity,
            min: 0.0, max: 1.0
        )
        let maxEdges = Self.clamp(
            req.uri.queryParameters["maxEdgesPerNode"].flatMap { Int($0) }
                ?? MemoryGraphService.defaultMaxEdgesPerNode,
            min: 1, max: MemoryGraphService.maxMaxEdgesPerNode
        )
        // `includeWikiPages` defaults true; `kinds` is a CSV of edge kinds
        // (wikilink,tag,space,semantic,temporal). Absent / empty → all kinds.
        let includeWikiPages = req.uri.queryParameters["includeWikiPages"]
            .map { $0 == "true" || $0 == "1" } ?? true
        let kinds = Self.parseEdgeKinds(req.uri.queryParameters["kinds"].map(String.init))
        let filter = try Self.parseGraphFilter(req)

        return try await graphService.graph(
            tenantID: tenantID,
            limit: limit,
            similarity: similarity,
            maxEdgesPerNode: maxEdges,
            includeWikiPages: includeWikiPages,
            kinds: kinds,
            filter: filter
        )
    }

    private static func parseGraphFilter(_ request: Request) throws -> MemoryGraphFilter {
        let query = request.uri.queryParameters
        let sources = Set(csv(query["sources"]).compactMap(MemorySourceKindDTO.init(rawValue:)))
        if let raw = query["sources"], !raw.isEmpty, sources.isEmpty {
            throw HTTPError(.badRequest, message: "sources contains no recognized values")
        }
        return MemoryGraphFilter(
            providers: Set(csv(query["providers"])),
            models: Set(csv(query["models"])),
            sources: sources,
            createdAfter: try parseDate(query["createdAfter"], name: "createdAfter"),
            createdBefore: try parseDate(query["createdBefore"], name: "createdBefore")
        )
    }

    private static func csv(_ value: Substring?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private static func parseDate(_ value: Substring?, name: String) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = ISO8601DateFormatter().date(from: String(value)) else {
            throw HTTPError(.badRequest, message: "\(name) must be ISO-8601")
        }
        return date
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

    /// Parses a CSV of edge-kind names into a set, dropping unknowns. A nil or
    /// empty parameter yields every edge kind.
    private static func parseEdgeKinds(_ csv: String?) -> Set<MemoryEdgeKindDTO> {
        guard let csv, !csv.isEmpty else { return MemoryGraphService.allEdgeKinds }
        let parsed = Set(csv.split(separator: ",").compactMap {
            MemoryEdgeKindDTO(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
        return parsed.isEmpty ? MemoryGraphService.allEdgeKinds : parsed
    }
}
