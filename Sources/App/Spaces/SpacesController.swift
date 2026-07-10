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
            createdAt: space.createdAt
        )
    }
}

struct SpacesController {
    let service: SpacesService
    let vaultAccess: VaultAccessService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("", use: create)
        router.get("/:id", use: getOne)
        router.put("/:id", use: update)
        router.delete("/:id", use: delete)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> SpaceListResponse {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read)
        let spaces = try await service.list(tenantID: access.vaultID)
        return try SpaceListResponse(spaces: spaces.map(SpaceDTO.fromSpace))
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write)
        let body = try await req.decode(as: CreateSpaceRequest.self, context: ctx)
        let space = try await service.create(
            tenantID: access.vaultID,
            name: body.name,
            slugRaw: body.slug ?? "",
            description: body.description,
            color: body.color,
            icon: body.icon,
            category: body.category
        )
        return try SpaceDTO.fromSpace(space)
    }

    @Sendable
    func getOne(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read)
        let id = try Self.parseID(ctx)
        let space = try await service.get(tenantID: access.vaultID, id: id)
        return try SpaceDTO.fromSpace(space)
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> SpaceDTO {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write)
        let id = try Self.parseID(ctx)
        let body = try await req.decode(as: UpdateSpaceRequest.self, context: ctx)
        let space = try await service.update(
            tenantID: access.vaultID,
            id: id,
            name: body.name,
            description: body.description,
            color: body.color,
            icon: body.icon,
            category: body.category
        )
        return try SpaceDTO.fromSpace(space)
    }

    @Sendable
    func delete(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .write)
        let id = try Self.parseID(ctx)
        try await service.delete(tenantID: access.vaultID, id: id)
        return Response(status: .noContent)
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid space id")
        }
        return id
    }
}
