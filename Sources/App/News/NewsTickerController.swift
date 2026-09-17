import Foundation
import Hummingbird
import LuminaVaultShared

extension NewsTickerResponse: @retroactive ResponseEncodable {}

/// `/v1/news` — the Home strip of the first-party `news-ticker` plugin:
///   GET /ticker?limit=   headlines for the tenant's installed, enabled plugin
///
/// 404 `plugin_not_installed` / 409 `plugin_disabled` come from the plugin
/// lifecycle; enable/disable is the existing PATCH /v1/plugins/installs/:id.
struct NewsTickerController {
    let service: NewsTickerService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("ticker", use: ticker)
    }

    @Sendable
    func ticker(_ req: Request, ctx: AppRequestContext) async throws -> NewsTickerResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = req.uri.queryParameters.get("limit").flatMap { Int($0) } ?? 30
        return try await service.ticker(tenantID: tenantID, limit: limit)
    }
}
