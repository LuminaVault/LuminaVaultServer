import Foundation
import Hummingbird
import LuminaVaultShared

extension ResurfaceResponse: @retroactive ResponseEncodable {}

/// `GET /v1/me/resurface?limit=3` — memories worth another look today. Read
/// of own data: mounted with `/v1/me/today` and `/v1/me/recap` (JWT +
/// per-user rate limit, no entitlement gate).
struct MeResurfaceController {
    let service: MeResurfaceService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/resurface", use: resurface)
    }

    @Sendable
    func resurface(_ request: Request, ctx: AppRequestContext) async throws -> ResurfaceResponse {
        let user = try ctx.requireIdentity()
        let limit = try Self.parseLimit(request.uri.queryParameters["limit"].map(String.init))
        return try await service.build(user: user, limit: limit)
    }

    /// 1…10, default 3. Anything else is a 400, like `/v1/me/recap?range=`.
    static func parseLimit(_ raw: String?) throws -> Int {
        guard let raw, !raw.isEmpty else { return MeResurfaceService.defaultLimit }
        guard let limit = Int(raw), (1 ... MeResurfaceService.maxLimit).contains(limit) else {
            throw HTTPError(.badRequest, message: "limit must be between 1 and \(MeResurfaceService.maxLimit)")
        }
        return limit
    }
}
