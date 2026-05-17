import AppAPI
import Foundation
import Hummingbird
import LuminaVaultShared

// /spaces DTOs are OpenAPI-generated in `Sources/AppAPI/openapi.yaml`.
// The typealiases below alias the generated schema names to the call-site
// names used by `SpacesController` + `SpacesService`.
typealias SpaceDTO = Components.Schemas.SpaceDTO
typealias SpaceListResponse = Components.Schemas.SpaceListResponse
typealias CreateSpaceRequest = Components.Schemas.SpaceCreateRequest
typealias UpdateSpaceRequest = Components.Schemas.SpaceUpdateRequest

extension SpaceDTO: ResponseEncodable {}
extension SpaceListResponse: ResponseEncodable {}

/// Server-only helper to create a SpaceDTO from a Fluent model.
extension SpaceDTO {
    static func fromSpace(_ space: Space) throws -> SpaceDTO {
        try SpaceDTO(
            id: space.requireID().uuidString,
            name: space.name,
            slug: space.slug,
            description: space.spaceDescription,
            color: space.color,
            icon: space.icon,
            category: space.category,
            noteCount: space.noteCount,
            lastCompiledAt: space.lastCompiledAt,
            createdAt: space.createdAt,
        )
    }
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
        return try SpaceListResponse(spaces: spaces.map(SpaceDTO.fromSpace))
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: CreateSpaceRequest.self, context: ctx)
        let space = try await service.create(
            tenantID: user.requireID(),
            name: body.name,
            slugRaw: body.slug ?? "",
            description: body.description,
            color: body.color,
            icon: body.icon,
            category: body.category,
        )
        return try SpaceDTO.fromSpace(space)
    }

    @Sendable
    func getOne(_: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let user = try ctx.requireIdentity()
        let id = try Self.parseID(ctx)
        let space = try await service.get(tenantID: user.requireID(), id: id)
        return try SpaceDTO.fromSpace(space)
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
            category: body.category,
        )
        return try SpaceDTO.fromSpace(space)
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
