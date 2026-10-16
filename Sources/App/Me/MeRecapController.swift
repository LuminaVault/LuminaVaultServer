import Foundation
import Hummingbird
import LuminaVaultShared

extension MeRecapResponse: @retroactive ResponseEncodable {}

/// `GET /v1/me/recap?range=7d|30d` — the last 7 or 30 of the user's own
/// calendar days. Read of own data: mounted like `/v1/me/today` (JWT +
/// per-user rate limit, no entitlement gate).
struct MeRecapController {
    let service: MeRecapService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/recap", use: recap)
    }

    @Sendable
    func recap(_ request: Request, ctx: AppRequestContext) async throws -> MeRecapResponse {
        let user = try ctx.requireIdentity()
        let range = try Self.parseRange(request.uri.queryParameters["range"].map(String.init))
        return try await service.build(user: user, range: range)
    }

    /// `7d` (default) or `30d`. `90d` parses as an `AnalyticsRange` but a
    /// quarter is not a recap, so it is refused like any other value.
    static func parseRange(_ raw: String?) throws -> AnalyticsRange {
        guard let raw, !raw.isEmpty else { return .week }
        guard let range = AnalyticsRange(rawValue: raw), range == .week || range == .month else {
            throw HTTPError(.badRequest, message: "range must be 7d or 30d")
        }
        return range
    }
}
