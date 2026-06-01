import Foundation
import Hummingbird
import LuminaVaultShared

/// HER-43 (Slice 3b) — install/uninstall Hermes Hub skills into the caller's
/// own Hermes container. Mounted under `/v1/plugins` (tenant JWT), only when a
/// per-tenant container manager exists.
///
///   POST   /v1/plugins/hermes-skills/install?id=<skillRef>  -> refreshed list
///   DELETE /v1/plugins/hermes-skills/{name}                 -> refreshed list
///
/// Both return the refreshed read-only `PluginCatalogListResponse` of the
/// tenant's Hermes-installed skills (reusing the Slice 3a shape — no new DTOs).
struct HermesHubSkillsController {
    let service: HermesHubSkillsService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("hermes-skills/install", use: install)
        router.delete("hermes-skills/:name", use: uninstall)
    }

    @Sendable
    func install(_ req: Request, ctx: AppRequestContext) async throws -> PluginCatalogListResponse {
        let tenantID = try ctx.requireTenantID()
        guard let id = req.uri.queryParameters.get("id"), !id.isEmpty else {
            throw HTTPError(.badRequest, message: "missing id query parameter")
        }
        let items = try await service.install(tenantID: tenantID, skillRef: id)
        return PluginCatalogListResponse(items: items)
    }

    @Sendable
    func uninstall(_: Request, ctx: AppRequestContext) async throws -> PluginCatalogListResponse {
        let tenantID = try ctx.requireTenantID()
        guard let name = ctx.parameters.get("name"), !name.isEmpty else {
            throw HTTPError(.badRequest, message: "missing skill name")
        }
        let items = try await service.uninstall(tenantID: tenantID, skillRef: name)
        return PluginCatalogListResponse(items: items)
    }
}
