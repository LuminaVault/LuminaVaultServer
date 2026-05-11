import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

/// HER-147 sweep summary across all users.
struct MemoryPruningSweepSummary: Codable, Sendable {
    let usersScanned: Int
    let scoreRowsUpdated: Int
    let memoriesArchived: Int
    let perTenant: [MemoryPruneResult]
    let failures: [String]
}

/// HER-147 driver — host cron POSTs monthly:
///
///   curl -X POST -H "X-Admin-Token: $T" $BASE/v1/admin/memory/prune
///
/// Recomputes every tenant's `score` first, then runs the prune
/// predicate per tenant. One bad tenant doesn't abort the sweep —
/// errors accumulate in `failures[]`.
struct MemoryPruningJob: Sendable {
    let fluent: Fluent
    let scoring: MemoryScoringService
    let pruning: MemoryPruningService
    let logger: Logger

    func runForAllUsers(now: Date = Date()) async throws -> MemoryPruningSweepSummary {
        let users = try await User.query(on: fluent.db()).all()
        var scoreRowsUpdated = 0
        var totalArchived = 0
        var perTenant: [MemoryPruneResult] = []
        var failures: [String] = []

        for user in users {
            do {
                let tenantID = try user.requireID()
                let rows = try await scoring.recomputeForTenant(tenantID: tenantID, now: now)
                scoreRowsUpdated += rows
                let pruneResult = try await pruning.pruneForTenant(tenantID: tenantID, now: now)
                totalArchived += pruneResult.archived
                if pruneResult.candidatesScanned > 0 {
                    perTenant.append(pruneResult)
                }
            } catch {
                failures.append("\(user.username): \(error)")
                logger.warning("prune failed for \(user.username): \(error)")
            }
        }

        logger.info("memory prune sweep: tenants=\(users.count) scored=\(scoreRowsUpdated) archived=\(totalArchived) failures=\(failures.count)")
        return MemoryPruningSweepSummary(
            usersScanned: users.count,
            scoreRowsUpdated: scoreRowsUpdated,
            memoriesArchived: totalArchived,
            perTenant: perTenant,
            failures: failures
        )
    }
}
