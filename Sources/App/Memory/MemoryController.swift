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

/// Single-memory representation for list / get / patch responses.
struct MemoryDTO: Codable, ResponseEncodable, Sendable {
    let id: UUID
    let content: String
    let tags: [String]
    let createdAt: Date?

    init(_ memory: Memory) throws {
        self.id = try memory.requireID()
        self.content = memory.content
        self.tags = memory.tags ?? []
        self.createdAt = memory.createdAt
    }
}

struct MemoryListResponse: Codable, ResponseEncodable, Sendable {
    let memories: [MemoryDTO]
    let limit: Int
    let offset: Int
}

/// PATCH body. All fields optional. `content` change triggers re-embed.
/// `tags == nil` leaves tags untouched; pass `[]` to clear.
struct MemoryPatchRequest: Codable, Sendable {
    let content: String?
    let tags: [String]?
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

    private static let defaultLimit = 20
    private static let maxLimit = 100

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/upsert", use: upsert)
        router.post("/search", use: search)
        router.get("", use: list)
        router.get("/:id", use: getOne)
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
            min: 1, max: Self.maxLimit
        )
        let offset = max(0, req.uri.queryParameters["offset"].flatMap { Int($0) } ?? 0)
        let tag = req.uri.queryParameters["tag"].map { String($0) }

        let rows = try await repository.listPaginated(
            tenantID: tenantID,
            tag: tag,
            limit: limit,
            offset: offset
        )
        return MemoryListResponse(
            memories: try rows.map(MemoryDTO.init),
            limit: limit,
            offset: offset
        )
    }

    @Sendable
    func getOne(_ req: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        guard let row = try await repository.find(tenantID: try user.requireID(), id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        return try MemoryDTO(row)
    }

    @Sendable
    func delete(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let deleted = try await repository.delete(tenantID: try user.requireID(), id: id)
        guard deleted else { throw HTTPError(.notFound, message: "memory not found") }
        return Response(status: .noContent)
    }

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> MemoryDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let tenantID = try user.requireID()
        let body = try await req.decode(as: MemoryPatchRequest.self, context: ctx)

        guard body.content != nil || body.tags != nil else {
            throw HTTPError(.badRequest, message: "patch body must include content and/or tags")
        }

        if let content = body.content {
            guard !content.isEmpty else {
                throw HTTPError(.badRequest, message: "content cannot be empty")
            }
            let embedding = try await embeddings.embed(content)
            let updated = try await repository.updateContent(
                tenantID: tenantID, id: id, content: content, embedding: embedding
            )
            guard updated else { throw HTTPError(.notFound, message: "memory not found") }
        }

        if let tags = body.tags {
            let updated = try await repository.updateTags(tenantID: tenantID, id: id, tags: tags)
            guard updated else { throw HTTPError(.notFound, message: "memory not found") }
        }

        guard let row = try await repository.find(tenantID: tenantID, id: id) else {
            throw HTTPError(.notFound, message: "memory not found")
        }
        return try MemoryDTO(row)
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
}
