import Foundation
import Hummingbird
import LuminaVaultShared

extension QueryResponse: ResponseEncodable {}

/// Natural-language query against the user's memories. Thin wrapper on top
/// of `HermesMemoryService.search` — keeps a stable URL for the iOS client
/// even if the underlying agent loop changes shape.
struct QueryController {
    let service: HermesMemoryService
    let achievements: AchievementsService?

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: query)
    }

    @Sendable
    func query(_ req: Request, ctx: AppRequestContext) async throws -> QueryResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: QueryRequest.self, context: ctx)
        guard !body.query.isEmpty else {
            throw HTTPError(.badRequest, message: "query required")
        }
        let tenantID = try user.requireID()
        let answer = try await service.search(
            tenantID: tenantID,
            profileUsername: user.username,
            query: body.query,
            limit: body.limit ?? 5,
        )
        if let achievements {
            Task.detached { await achievements.recordAndPush(tenantID: tenantID, event: .queryRan) }
        }
        let hits = answer.hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return QueryResponse(summary: answer.summary, hits: hits)
    }
}
