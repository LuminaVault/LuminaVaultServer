import Foundation
import Hummingbird
import LuminaVaultShared

extension KnowledgeGraphResponse: @retroactive ResponseEncodable {}
extension ConnectionExplanationResponse: @retroactive ResponseEncodable {}
extension ReasoningQueryResponse: @retroactive ResponseEncodable {}
extension KnowledgeEdgeDTO: @retroactive ResponseEncodable {}

struct KnowledgeGraphController {
    let service: KnowledgeGraphService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/graph", use: graph)
        router.post("/reason", use: reason)
        router.post("/reason/stream", use: reasonStream)
        router.post("/connections/explain", use: explain)
        router.post("/edges/:id/confirm", use: confirm)
        router.post("/edges/:id/dismiss", use: dismiss)
    }

    @Sendable
    func graph(_ req: Request, ctx: AppRequestContext) async throws -> KnowledgeGraphResponse {
        let tenantID = try ctx.requireTenantID()
        let query = req.uri.queryParameters
        let limit = min(max(query["limit"].flatMap { Int($0) } ?? KnowledgeGraphService.defaultLimit, 1), KnowledgeGraphService.maxLimit)
        let confidence = min(max(query["minimumConfidence"].flatMap { Double($0) } ?? 0, 0), 1)
        let kinds = Set(csv(query["kinds"]).compactMap(KnowledgeNodeKindDTO.init(rawValue:)))
        let predicates = Set(csv(query["predicates"]).compactMap(KnowledgeEdgePredicateDTO.init(rawValue:)))
        let requestedStates = Set(csv(query["states"]).compactMap(KnowledgeEdgeStateDTO.init(rawValue:)))
        let states: Set<KnowledgeEdgeStateDTO> = requestedStates.isEmpty ? [.asserted, .suggested, .confirmed] : requestedStates
        return try await service.graph(
            tenantID: tenantID,
            limit: limit,
            filter: KnowledgeGraphFilter(kinds: kinds, predicates: predicates, states: states, minimumConfidence: confidence)
        )
    }

    @Sendable
    func explain(_ req: Request, ctx: AppRequestContext) async throws -> ConnectionExplanationResponse {
        let body = try await req.decode(as: ConnectionExplanationRequest.self, context: ctx)
        return try await service.explain(
            tenantID: ctx.requireTenantID(),
            from: body.fromNodeID,
            to: body.toNodeID,
            maxDepth: body.maxDepth ?? KnowledgeGraphService.maxDepth
        )
    }

    @Sendable
    func reason(_ req: Request, ctx: AppRequestContext) async throws -> ReasoningQueryResponse {
        let body = try await req.decode(as: ReasoningQueryRequest.self, context: ctx)
        return try await service.reason(tenantID: ctx.requireTenantID(), request: body)
    }

    @Sendable
    func reasonStream(_ req: Request, ctx: AppRequestContext) async throws -> KnowledgeReasoningSSEResponse {
        let body = try await req.decode(as: ReasoningQueryRequest.self, context: ctx)
        let tenantID = try ctx.requireTenantID()
        let service = service
        let (events, continuation) = AsyncThrowingStream<ReasoningStreamEventDTO, Error>.makeStream()
        let work = Task {
            do {
                let response = try await service.reason(tenantID: tenantID, request: body)
                continuation.yield(ReasoningStreamEventDTO(type: "result", response: response))
                continuation.yield(ReasoningStreamEventDTO(type: "done"))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return KnowledgeReasoningSSEResponse(events: events)
    }

    @Sendable
    func confirm(_ req: Request, ctx: AppRequestContext) async throws -> KnowledgeEdgeDTO {
        try await review(req, ctx: ctx, state: .confirmed)
    }

    @Sendable
    func dismiss(_ req: Request, ctx: AppRequestContext) async throws -> KnowledgeEdgeDTO {
        try await review(req, ctx: ctx, state: .dismissed)
    }

    private func review(_ req: Request, ctx: AppRequestContext, state: KnowledgeEdgeStateDTO) async throws -> KnowledgeEdgeDTO {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid edge id")
        }
        let body = try await req.decode(as: InferenceReviewRequest.self, context: ctx)
        return try await service.review(tenantID: ctx.requireTenantID(), edgeID: id, state: state, note: body.note)
    }

    private func csv(_ value: Substring?) -> [String] {
        value?.split(separator: ",").map(String.init) ?? []
    }
}
