import Foundation
import Hummingbird
import LuminaVaultShared

/// P3 — `GET /v1/me/hermes/capabilities`. Reports what the tenant's
/// connected Hermes exposes so clients can gate each settings pane. Managed
/// tenants get `HermesCapabilities.managedDefault`; BYO tenants get a
/// (cached) probe of their remote `api_server`. `?refresh=true` forces a
/// re-probe past the cache TTL.
struct HermesCapabilitiesController {
    let service: HermesRemoteCapabilitiesService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: get)
    }

    @Sendable
    func get(_ req: Request, ctx: AppRequestContext) async throws -> HermesCapabilitiesResponse {
        let tenantID = try ctx.requireTenantID()
        let force = req.uri.queryParameters["refresh"] == "true"
        return await service.capabilities(tenantID: tenantID, force: force)
    }
}

extension HermesCapabilitiesResponse: ResponseEncodable {}
