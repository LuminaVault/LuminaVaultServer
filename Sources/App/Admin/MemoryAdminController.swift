import Foundation
import Hummingbird

extension MemoryPruningSweepSummary: ResponseEncodable {}
extension MemoryPruneResult: ResponseEncodable {}

/// HER-147 single-user score recompute response.
struct MemoryRecomputeResponse: Codable, ResponseEncodable {
    let tenantID: UUID?
    let rowsUpdated: Int
}

/// HER-147 — admin endpoints for the monthly memory pruning job.
/// Mounted at `/v1/admin/memory` behind `AdminTokenMiddleware`.
///
/// Host cron (monthly) drives this via:
///
///   curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/memory/prune
///
/// Per-user errors do not abort the sweep; they accumulate in the
/// `failures[]` array of the response body.
struct MemoryAdminController {
    let scoring: MemoryScoringService
    let pruning: MemoryPruningService
    let job: MemoryPruningJob

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("/recompute", use: recomputeAll)
        router.post("/recompute/:userID", use: recomputeOne)
        router.post("/prune", use: pruneAll)
        router.post("/prune/:userID", use: pruneOne)
    }

    @Sendable
    func recomputeAll(_: Request, ctx _: AppRequestContext) async throws -> MemoryRecomputeResponse {
        let rows = try await scoring.recomputeAll()
        return MemoryRecomputeResponse(tenantID: nil, rowsUpdated: rows)
    }

    @Sendable
    func recomputeOne(_: Request, ctx: AppRequestContext) async throws -> MemoryRecomputeResponse {
        let tenantID = try Self.parseUserID(ctx)
        let rows = try await scoring.recomputeForTenant(tenantID: tenantID)
        return MemoryRecomputeResponse(tenantID: tenantID, rowsUpdated: rows)
    }

    @Sendable
    func pruneAll(_: Request, ctx _: AppRequestContext) async throws -> MemoryPruningSweepSummary {
        try await job.runForAllUsers()
    }

    @Sendable
    func pruneOne(_: Request, ctx: AppRequestContext) async throws -> MemoryPruneResult {
        let tenantID = try Self.parseUserID(ctx)
        // Recompute first so the prune predicate sees fresh scores.
        _ = try await scoring.recomputeForTenant(tenantID: tenantID)
        return try await pruning.pruneForTenant(tenantID: tenantID)
    }

    private static func parseUserID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("userID"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid userID")
        }
        return id
    }
}
