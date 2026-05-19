import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension DashboardStatsResponse: ResponseEncodable {}

struct DashboardController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/stats", use: stats)
    }

    @Sendable
    func stats(_: Request, ctx: AppRequestContext) async throws -> DashboardStatsResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()

        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: Date())

        let memoriesTotal = try await Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()

        let memoriesToday = try await Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$createdAt >= startOfDay)
            .count()

        let latestCompiledSpace = try await Space.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$lastCompiledAt != nil)
            .sort(\.$lastCompiledAt, .descending)
            .first()

        return DashboardStatsResponse(
            memoriesToday: memoriesToday,
            memoriesTotal: memoriesTotal,
            lastCompileAt: latestCompiledSpace?.lastCompiledAt,
        )
    }
}
