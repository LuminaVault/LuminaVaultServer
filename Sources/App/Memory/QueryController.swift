import Foundation
import Hummingbird

struct QueryRequest: Codable, Sendable {
    let query: String
    let limit: Int?
}

struct QueryHitDTO: Codable, Sendable {
    let id: UUID
    let content: String
    let distance: Float
    let createdAt: Date?
}

struct QueryResponse: Codable, ResponseEncodable, Sendable {
    let summary: String
    let hits: [QueryHitDTO]
}

/// Natural-language query against the user's memories. Thin wrapper on top
/// of `HermesMemoryService.search` — keeps a stable URL for the iOS client
/// even if the underlying agent loop changes shape.
struct QueryController {
    let service: HermesMemoryService

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
        let answer = try await service.search(
            tenantID: try user.requireID(),
            profileUsername: user.username,
            query: body.query,
            limit: body.limit ?? 5
        )
        let hits = answer.hits.map {
            QueryHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return QueryResponse(summary: answer.summary, hits: hits)
    }
}
