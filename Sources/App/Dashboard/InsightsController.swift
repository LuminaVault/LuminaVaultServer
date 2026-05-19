import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension InsightListResponse: ResponseEncodable {}

/// `GET /v1/insights` — list proactive findings ("what Lumina noticed")
/// for the authenticated tenant.
///
/// HER-244: initial implementation always returns an empty list. Real
/// insight generation ships under HER-248, backed by the pattern (HER-189)
/// and contradiction (HER-190) skills.
struct InsightsController {
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> InsightListResponse {
        _ = try ctx.requireIdentity()
        _ = Self.parseSection(req)
        _ = Self.parseLimit(req)
        return InsightListResponse(insights: [], nextCursor: nil)
    }

    private static func parseSection(_ req: Request) -> InsightSection? {
        guard let raw = req.uri.queryParameters["section"] else { return nil }
        return InsightSection(rawValue: String(raw))
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }
}
