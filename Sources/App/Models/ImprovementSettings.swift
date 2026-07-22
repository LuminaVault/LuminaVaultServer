import FluentKit
import Foundation
import LuminaVaultShared

final class ImprovementSettings: Model, TenantModel, @unchecked Sendable {
    static let schema = "self_improvement_settings"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "enabled") var enabled: Bool
    @Field(key: "curator_enabled") var curatorEnabled: Bool
    @Field(key: "interval_hours") var intervalHours: Int
    @Field(key: "minimum_idle_hours") var minimumIdleHours: Int
    @Field(key: "consolidate") var consolidate: Bool
    @Field(key: "prune_builtins") var pruneBuiltins: Bool
    @Field(key: "backup_keep") var backupKeep: Int
    @Field(key: "soul_review_enabled") var soulReviewEnabled: Bool
    @Field(key: "review_complex_sessions") var reviewComplexSessions: Bool
    @Field(key: "soul_review_window_days") var soulReviewWindowDays: Int
    @Field(key: "soul_review_cooldown_hours") var soulReviewCooldownHours: Int
    @Field(key: "model_mode") var modelMode: String
    @OptionalField(key: "last_activity_at") var lastActivityAt: Date?
    @OptionalField(key: "last_curator_review_at") var lastCuratorReviewAt: Date?
    @OptionalField(key: "last_soul_review_at") var lastSoulReviewAt: Date?
    @OptionalField(key: "next_review_at") var nextReviewAt: Date?
    @OptionalField(key: "lease_until") var leaseUntil: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(tenantID: UUID, now: Date = Date()) {
        self.tenantID = tenantID
        apply(.safeDefault)
        nextReviewAt = Calendar(identifier: .gregorian).date(byAdding: .hour, value: 168, to: now)
    }

    func apply(_ dto: ImprovementSettingsDTO) {
        enabled = dto.enabled
        curatorEnabled = dto.curatorEnabled
        intervalHours = dto.intervalHours
        minimumIdleHours = dto.minimumIdleHours
        consolidate = dto.consolidate
        pruneBuiltins = dto.pruneBuiltins
        backupKeep = dto.backupKeep
        soulReviewEnabled = dto.soulReviewEnabled
        reviewComplexSessions = dto.reviewComplexSessions
        soulReviewWindowDays = dto.soulReviewWindowDays
        soulReviewCooldownHours = dto.soulReviewCooldownHours
        modelMode = dto.modelMode.rawValue
    }

    func toDTO() -> ImprovementSettingsDTO {
        ImprovementSettingsDTO(
            enabled: enabled,
            curatorEnabled: curatorEnabled,
            intervalHours: intervalHours,
            minimumIdleHours: minimumIdleHours,
            consolidate: consolidate,
            pruneBuiltins: pruneBuiltins,
            backupKeep: backupKeep,
            soulReviewEnabled: soulReviewEnabled,
            reviewComplexSessions: reviewComplexSessions,
            soulReviewWindowDays: soulReviewWindowDays,
            soulReviewCooldownHours: soulReviewCooldownHours,
            modelMode: ImprovementModelMode(rawValue: modelMode) ?? .economy
        )
    }
}
