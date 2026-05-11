import Foundation
import Hummingbird

struct CreateSpaceRequest: Codable {
    let name: String
    let slug: String
    let description: String?
    let color: String?
    let icon: String?
}

struct UpdateSpaceRequest: Codable {
    let name: String?
    let description: String?
    let color: String?
    let icon: String?
}

struct SpaceDTO: Codable, ResponseEncodable {
    let id: UUID
    let name: String
    let slug: String
    let description: String?
    let color: String?
    let icon: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(_ space: Space) throws {
        id = try space.requireID()
        name = space.name
        slug = space.slug
        description = space.spaceDescription
        color = space.color
        icon = space.icon
        createdAt = space.createdAt
        updatedAt = space.updatedAt
    }
}

struct SpaceListResponse: Codable, ResponseEncodable {
    let spaces: [SpaceDTO]
}

struct SpacesController {
    let service: SpacesService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.get("/:id", use: getOne)
        router.put("/:id", use: update)
        router.delete("/:id", use: delete)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> SpaceListResponse {
        let user = try ctx.requireIdentity()
        let spaces = try await service.list(tenantID: user.requireID())
        return try SpaceListResponse(spaces: spaces.map(SpaceDTO.init))
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: CreateSpaceRequest.self, context: ctx)
        let space = try await service.create(
            tenantID: user.requireID(),
            name: body.name,
            slugRaw: body.slug,
            description: body.description,
            color: body.color,
            icon: body.icon,
        )
        return try SpaceDTO(space)
    }

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let space = try await service.get(tenantID: user.requireID(), id: id)
        return try SpaceDTO(space)
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let body = try await req.decode(as: UpdateSpaceRequest.self, context: ctx)
        let space = try await service.update(
            tenantID: user.requireID(),
            id: id,
            name: body.name,
            description: body.description,
            color: body.color,
            icon: body.icon,
        )
        return try SpaceDTO(space)
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        try await service.delete(tenantID: user.requireID(), id: id)
        return Response(status: .noContent)
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid space id")
        }
        return id
    }
}
