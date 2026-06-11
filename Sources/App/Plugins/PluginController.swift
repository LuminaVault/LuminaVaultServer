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
        router.get("hermes-skills", use: hermesSkills)
        router.get("installs", use: listInstalls)
        router.post("installs", use: install)
        router.patch("installs/:id", use: update)
        router.delete("installs/:id", use: delete)
        router.post("installs/:id/sync", use: sync)
    }

    @Sendable
    func catalog(_ req: Request, ctx: AppRequestContext) async throws -> PluginCatalogListResponse {
        let tenantID = try ctx.requireTenantID()
        let category = req.uri.queryParameters.get("category").flatMap { PluginCategory(rawValue: $0) }
        // HER-43 Slice 6 — optional curation filters: ?featured=true / ?premium=true.
        let featured = Self.boolQuery(req, "featured")
        let premium = Self.boolQuery(req, "premium")
        return await PluginCatalogListResponse(
            items: service.listCatalog(tenantID: tenantID, category: category, featured: featured, premium: premium)
        )
    }

    /// HER-43 Slice 3a — read-only list of skills installed in the tenant's
    /// Hermes agent (proxied from Hermes `GET /v1/skills`). Empty when Hermes
    /// is unresolved/unreachable. Hub install lands in Slice 3b.
    @Sendable
    func hermesSkills(_: Request, ctx: AppRequestContext) async throws -> PluginCatalogListResponse {
        _ = try ctx.requireTenantID()
        let items = await service.hermesInstalledSkills(
            baseURL: ctx.hermesResolution?.baseURL,
            authHeader: ctx.hermesResolution?.authHeader
        )
        return PluginCatalogListResponse(items: items)
    }

    @Sendable
    func listInstalls(_: Request, ctx: AppRequestContext) async throws -> PluginInstallsListResponse {
        let tenantID = try ctx.requireTenantID()
        return try await PluginInstallsListResponse(items: service.listInstalls(tenantID: tenantID))
    }

    @Sendable
    func install(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let body = try await req.decode(as: InstallPluginRequest.self, context: ctx)
        // HER-43 Slice 6 — premium plugins require the paid tier. 402 mirrors
        // PremiumGuardMiddleware so the client can route to the paywall.
        if PluginCatalog.isPremium(slug: body.pluginSlug), !Self.entitledToPremium(user) {
            throw HTTPError(.init(code: 402, reasonPhrase: "Payment Required"), message: "premium_required")
        }
        return try await service.install(tenantID: tenantID, slug: body.pluginSlug, config: body.config)
    }

    /// Pro/ultimate gate, honoring `tier_override` (matches PremiumGuardMiddleware).
    private static func entitledToPremium(_ user: User) -> Bool {
        let effective = user.tierOverride != "none" ? user.tierOverride : user.tier
        return ["pro", "ultimate"].contains(effective)
    }

    private static func boolQuery(_ req: Request, _ key: String) -> Bool? {
        guard let raw = req.uri.queryParameters.get(key) else { return nil }
        return raw == "true" || raw == "1"
    }

    @Sendable
    func update(_ req: Request, ctx: AppRequestContext) async throws -> PluginInstallDTO {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.installID(ctx)
        let body = try await req.decode(as: UpdatePluginInstallRequest.self, context: ctx)
        return try await service.update(
            tenantID: tenantID, installID: id, config: body.config, status: body.status
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
