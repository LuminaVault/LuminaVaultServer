import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension SkillOutputListResponse: ResponseEncodable {}

/// `GET /v1/skills/outputs` — Today-tab skill outputs feed.
///
/// HER-177 — initial implementation returns an empty list. Real output
/// persistence + join across memos / memories / vault files lands once
/// `SkillRunner` dispatches outputs (HER-169) and writes them with the
/// metadata required to drive the Today cards.
struct SkillOutputsController {
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/outputs", use: list)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> SkillOutputListResponse {
        _ = try ctx.requireIdentity()
        return SkillOutputListResponse(
            outputs: [],
            streakDays: 0,
            activeRun: false,
            nextCursor: nil
        )
    }
}
