import FluentKit
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

// HER-43 (Slice 1) — plugin DTOs live in LuminaVaultShared. Server-side
// `ResponseEncodable` conformances for the response types. `AppRequestContext`
// uses Hummingbird's default (camelCase) decoder, and the shared DTOs are
// plain camelCase Codable, so they decode/encode directly.
extension PluginCatalogListResponse: @retroactive ResponseEncodable {}
extension PluginInstallsListResponse: @retroactive ResponseEncodable {}
extension PluginInstallDTO: @retroactive ResponseEncodable {}
extension PluginSyncResponse: @retroactive ResponseEncodable {}

/// `/v1/plugins` — declarative plugin foundation:
///   GET    /catalog                  list first-party plugins (?category=)
///   GET    /installs                 this tenant's installs
///   POST   /installs                 install { pluginSlug, config }
///   PATCH  /installs/:id             update config / enable-disable
///   DELETE /installs/:id             uninstall
///   POST   /installs/:id/sync        run a connector install now
struct PluginController {
    let service: PluginService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("catalog", use: catalog)
        router.get("installs", use: listInstalls)
        router.post("installs", use: install)
        router.patch("installs/:id", use: update)
        router.delete("installs/:id", use: delete)
        router.post("installs/:id/sync", use: sync)
    }

    @Sendable
    func catalog(_ req: Request, ctx: AppRequestContext) async throws -> PluginCatalogListResponse {
        _ = try ctx.requireTenantID()
        let category = req.uri.queryParameters.get("category").flatMap { PluginCategory(rawValue: $0) }
        return PluginCatalogListResponse(items: service.listCatalog(category: category))
    }

    @Sendable
    func listInstalls(_: Request, ctx: AppRequestContext) async throws -> PluginInstallsListResponse {
        let tenantID = try ctx.requireTenantID()
        return PluginInstallsListResponse(items: try await service.listInstalls(tenantID: tenantID))
    }

    @Sendable
    func install(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: InstallPluginRequest.self, context: ctx)
        return try await service.install(tenantID: tenantID, slug: body.pluginSlug, config: body.config)
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.installID(ctx)
        let body = try await req.decode(as: UpdatePluginInstallRequest.self, context: ctx)
        return try await service.update(
            tenantID: tenantID, installID: id, config: body.config, status: body.status,
        )
    }

    @Sendable
    func delete(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.installID(ctx)
        try await service.uninstall(tenantID: tenantID, installID: id)
        return Response(status: .noContent)
    }

    @Sendable
    func sync(_: Request, ctx: AppRequestContext) async throws -> PluginSyncResponse {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.installID(ctx)
        return try await service.sync(tenantID: tenantID, installID: id)
    }

    private static func installID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid plugin install id")
        }
        return id
    }
}
