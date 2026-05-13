import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension AchievementsListResponse: ResponseEncodable {}
extension AchievementsRecentResponse: ResponseEncodable {}

/// `GET /v1/achievements` and `GET /v1/achievements/recent` — read-only
/// views over `achievement_progress` for the JWT-authenticated tenant.
/// Mutation is fire-and-forget from the controller hot-paths; there is
/// intentionally no POST surface here.
struct AchievementsController {
    let service: AchievementsService
    let logger: Logger

    private static let recentDefaultLimit = 10
    private static let recentMaxLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.get("/recent", use: recent)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> AchievementsListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let progress = try await service.progress(for: tenantID)
        let archetypes = service.catalog.archetypes.map { archetype in
            AchievementsListResponse.ArchetypeDTO(
                key: archetype.key.rawValue,
                label: archetype.label,
                sub: archetype.subs.map { sub in
                    let row = progress[sub.key]
                    return AchievementsListResponse.SubDTO(
                        key: sub.key,
                        label: sub.label,
                        target: sub.target,
                        progress: row?.progressCount ?? 0,
                        unlockedAt: row?.unlockedAt,
                    )
                },
            )
        }
        return AchievementsListResponse(
            catalogVersion: service.catalog.catalogVersion,
            archetypes: archetypes,
        )
    }

    @Sendable
    func recent(_ req: Request, ctx: AppRequestContext) async throws -> AchievementsRecentResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let limit = Self.parseLimit(req)
        let rows = try await service.recentUnlocks(for: tenantID, limit: limit)
        let subsByKey = service.catalog.subsByKey
        let unlocks = rows.compactMap { row -> AchievementsRecentResponse.UnlockDTO? in
            guard let unlockedAt = row.unlockedAt else { return nil }
            let label = subsByKey[row.achievementKey]?.label ?? row.achievementKey
            return AchievementsRecentResponse.UnlockDTO(
                key: row.achievementKey,
                label: label,
                unlockedAt: unlockedAt,
            )
        }
        return AchievementsRecentResponse(unlocks: unlocks)
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return recentDefaultLimit
        }
        return max(1, min(raw, recentMaxLimit))
    }
}
