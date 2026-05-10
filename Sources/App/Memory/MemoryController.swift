import Foundation
import Hummingbird
import Logging

struct MemoryUpsertRequest: Codable, Sendable {
    let content: String
}

struct MemoryUpsertResponse: Codable, ResponseEncodable, Sendable {
    let memoryId: UUID
    let content: String
    let summary: String
}

struct MemorySearchRequest: Codable, Sendable {
    let query: String
    let limit: Int?
}

struct MemorySearchHitDTO: Codable, Sendable {
    let id: UUID
    let content: String
    let distance: Float
    let createdAt: Date?
}

struct MemorySearchResponse: Codable, ResponseEncodable, Sendable {
    let hits: [MemorySearchHitDTO]
    let summary: String
}

/// Routes the user's authenticated requests through the Hermes tool-calling
/// agent (`HermesMemoryService`). Profile name == username; tenancy comes
/// from the JWT subject claim via `AppRequestContext.requireIdentity`.
struct MemoryController {
    let service: HermesMemoryService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/upsert", use: upsert)
        router.post("/search", use: search)
    }

    @Sendable
    func upsert(_ req: Request, ctx: AppRequestContext) async throws -> MemoryUpsertResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemoryUpsertRequest.self, context: ctx)
        guard !body.content.isEmpty else {
            throw HTTPError(.badRequest, message: "content required")
        }
        let result = try await service.upsert(
            tenantID: try user.requireID(),
            profileUsername: user.username,
            content: body.content
        )
        return MemoryUpsertResponse(
            memoryId: try result.memory.requireID(),
            content: result.memory.content,
            summary: result.summary
        )
    }

    @Sendable
    func search(_ req: Request, ctx: AppRequestContext) async throws -> MemorySearchResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: MemorySearchRequest.self, context: ctx)
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
            MemorySearchHitDTO(id: $0.id, content: $0.content, distance: $0.distance, createdAt: $0.createdAt)
        }
        return MemorySearchResponse(hits: hits, summary: answer.summary)
    }
}
