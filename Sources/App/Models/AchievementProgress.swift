import FluentKit
import Foundation

/// Per-tenant counter + unlock timestamp for a single sub-achievement.
/// Schema in `M28_CreateAchievementProgress`. The catalog (keys, labels,
/// thresholds, archetypes) lives in `AchievementCatalog` — this table holds
/// only the per-user counters that map by `achievement_key`.
///
/// `unlockedAt` is set the first time `progressCount` crosses the catalog
/// threshold for this key and is never overwritten, making repeated events
/// past the threshold idempotent.
final class AchievementProgress: Model, TenantModel, @unchecked Sendable {
    static let schema = "achievement_progress"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "achievement_key") var achievementKey: String
    @Field(key: "progress_count") var progressCount: Int64
    @OptionalField(key: "unlocked_at") var unlockedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        tenantID: UUID,
        achievementKey: String,
        progressCount: Int64 = 0,
        unlockedAt: Date? = nil,
    ) {
        self.tenantID = tenantID
        self.achievementKey = achievementKey
        self.progressCount = progressCount
        self.unlockedAt = unlockedAt
    }
}
