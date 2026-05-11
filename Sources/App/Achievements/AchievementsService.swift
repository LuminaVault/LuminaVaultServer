import FluentKit
import Foundation
import HummingbirdFluent
import Logging

/// Owns per-tenant achievement counters.
///
/// `record(tenantID:event:)` is called fire-and-forget from controller
/// hot-paths (memory upsert, chat completion, KB compile, query, vault
/// upload, SOUL configure, space creation). For every sub-achievement
/// whose `event` matches, the row's `progress_count` is incremented and
/// — the first time `progress_count >= target` — `unlocked_at` is set.
/// Re-firing past the threshold is idempotent: `unlocked_at` is preserved.
///
/// Returns the set of sub-achievement keys that crossed their threshold
/// in this call so the caller can fan out APNS pushes via
/// `APNSNotificationService.notifyAchievement`.
///
/// Concurrency note: increments are not transactional — two events for
/// the same `(tenant_id, achievement_key)` racing in flight can lose one
/// counter increment. The unlock contract is preserved because both
/// writers see the same pre-threshold value and at most one observes the
/// crossing. The miscount is bounded by the number of concurrent events
/// per second per user and is acceptable for the scaffold. Harden with
/// a Postgres `INSERT ... ON CONFLICT DO UPDATE` upsert if it ever
/// becomes load-bearing.
struct AchievementsService {
    let fluent: Fluent
    let catalog: AchievementCatalog
    let logger: Logger

    init(
        fluent: Fluent,
        catalog: AchievementCatalog = .current,
        logger: Logger,
    ) {
        self.fluent = fluent
        self.catalog = catalog
        self.logger = logger
    }

    /// Records one occurrence of `event` for `tenantID`. Returns the keys
    /// of sub-achievements that became newly unlocked as a result.
    @discardableResult
    func record(tenantID: UUID, event: AchievementEvent) async throws -> [SubAchievement] {
        let subs = catalog.subs(matching: event)
        guard !subs.isEmpty else { return [] }
        let db = fluent.db()
        var newlyUnlocked: [SubAchievement] = []
        for sub in subs {
            let existing = try await AchievementProgress.query(on: db)
                .filter(\.$tenantID == tenantID)
                .filter(\.$achievementKey == sub.key)
                .first()
            let row = existing ?? AchievementProgress(tenantID: tenantID, achievementKey: sub.key)
            let wasUnlocked = row.unlockedAt != nil
            row.progressCount += 1
            if !wasUnlocked, row.progressCount >= sub.target {
                row.unlockedAt = Date()
                newlyUnlocked.append(sub)
            }
            try await row.save(on: db)
        }
        if !newlyUnlocked.isEmpty {
            logger.info("achievements.unlocked tenant=\(tenantID) keys=\(newlyUnlocked.map(\.key).joined(separator: ","))")
        }
        return newlyUnlocked
    }

    /// All rows for `tenantID`, keyed by `achievement_key`. Used by the
    /// catalog-join endpoint.
    func progress(for tenantID: UUID) async throws -> [String: AchievementProgress] {
        let rows = try await AchievementProgress.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        var out: [String: AchievementProgress] = [:]
        for row in rows {
            out[row.achievementKey] = row
        }
        return out
    }

    /// Most-recent unlocked entries (across all sub-achievements). Used by
    /// `GET /v1/achievements/recent`.
    func recentUnlocks(for tenantID: UUID, limit: Int) async throws -> [AchievementProgress] {
        let safeLimit = max(1, min(limit, 100))
        return try await AchievementProgress.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .filter(\.$unlockedAt != nil)
            .sort(\.$unlockedAt, .descending)
            .limit(safeLimit)
            .all()
    }
}
