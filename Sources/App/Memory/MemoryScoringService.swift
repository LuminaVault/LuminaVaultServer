import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import SQLKit

/// HER-147 scoring formula. Pure math, separated so the pruning job and
/// the periodic recompute share one definition.
///
/// `score = w_access * ln(1 + accessCount)
///        + w_query  * ln(1 + queryHitCount)
///        + w_recency * exp(-ageDays / halflifeDays)`
///
/// Defaults tuned so a freshly-created, never-accessed memory has score
/// ~= `w_recency` (1.0) and decays to half within `halflifeDays`. A
/// heavily-used memory (50 accesses, 20 query hits) sits ~ `2 * ln(51) +
/// 3 * ln(21) ≈ 17` even when very old — comfortably above the prune
/// threshold (default 0.2).
struct MemoryScoringConfig: Sendable {
    let accessWeight: Double
    let queryWeight: Double
    let recencyWeight: Double
    let halflifeDays: Double

    static let `default` = MemoryScoringConfig(
        accessWeight: 2.0,
        queryWeight: 3.0,
        recencyWeight: 1.0,
        halflifeDays: 30
    )
}

enum MemoryScoring {
    static func compute(
        accessCount: Int64,
        queryHitCount: Int64,
        createdAt: Date?,
        now: Date,
        config: MemoryScoringConfig = .default
    ) -> Double {
        let access = config.accessWeight * log1p(Double(accessCount))
        let queries = config.queryWeight * log1p(Double(queryHitCount))
        let ageDays: Double = {
            guard let createdAt else { return 0 }
            return max(0, now.timeIntervalSince(createdAt)) / 86_400
        }()
        let recency = config.recencyWeight * exp(-ageDays / config.halflifeDays)
        return access + queries + recency
    }
}

/// HER-147 — bulk score recompute. Run per-tenant before pruning, or
/// across all tenants on a less-frequent recompute cron. Stays in SQL so
/// a tenant with 10k memories doesn't pay 10k round-trips.
actor MemoryScoringService {
    let fluent: Fluent
    let config: MemoryScoringConfig
    let logger: Logger

    init(fluent: Fluent, config: MemoryScoringConfig = .default, logger: Logger) {
        self.fluent = fluent
        self.config = config
        self.logger = logger
    }

    /// Recomputes `score` for every memory belonging to `tenantID`. Returns
    /// the number of rows updated.
    @discardableResult
    func recomputeForTenant(tenantID: UUID, now: Date = Date()) async throws -> Int {
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for scoring update")
        }
        let halflifeSecs = config.halflifeDays * 86_400
        // Postgres has no `log1p`; `ln(1+x)` is the direct translation. The
        // formula matches `MemoryScoring.compute` exactly so unit tests on
        // the Swift side stay authoritative.
        let result = try await sql.raw("""
            UPDATE memories SET score =
                \(unsafeRaw: String(config.accessWeight)) * ln(1 + access_count)
              + \(unsafeRaw: String(config.queryWeight)) * ln(1 + query_hit_count)
              + \(unsafeRaw: String(config.recencyWeight)) * exp(
                    - GREATEST(0, EXTRACT(EPOCH FROM (\(bind: now) - COALESCE(created_at, \(bind: now))))::float8)
                    / \(unsafeRaw: String(halflifeSecs))
                )
            WHERE tenant_id = \(bind: tenantID)
            RETURNING id
            """).all()
        return result.count
    }

    /// Recompute for every user. Used by the admin sweep endpoint.
    @discardableResult
    func recomputeAll(now: Date = Date()) async throws -> Int {
        let users = try await User.query(on: fluent.db()).all()
        var total = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                total += try await recomputeForTenant(tenantID: tenantID, now: now)
            } catch {
                logger.warning("recompute failed tenant=\(tenantID): \(error)")
            }
        }
        logger.info("memory scoring recompute: tenants=\(users.count) rowsUpdated=\(total)")
        return total
    }
}
