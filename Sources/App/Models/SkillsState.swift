import FluentKit
import Foundation

/// Per-tenant runtime state for a skill. Composite primary key
/// `(tenant_id, source, name)` so a builtin and vault skill of the same
/// name can coexist (vault wins at SkillCatalog merge time).
///
/// Schema lives in M19_CreateSkillsState + M26_AddSkillsStateDailyRunCap.
/// Fluent's `@CompositeID` is awkward with three columns + a non-`id`
/// primary key, so this model exposes the columns directly and queries
/// pin the relevant fields rather than relying on `find(_:on:)`.
final class SkillsState: Model, TenantModel, @unchecked Sendable {
    static let schema = "skills_state"

    @ID(custom: "tenant_id", generatedBy: .user) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "source") var source: String // "builtin" | "vault"
    @Field(key: "name") var name: String
    @Field(key: "enabled") var enabled: Bool
    @OptionalField(key: "schedule_override") var scheduleOverride: String?
    /// One-shot fire time (#10, M75). When set with no cron schedule, the
    /// scheduler fires the skill once at/after this instant then disables the
    /// row. Null for recurring (cron) + built-in skills.
    @OptionalField(key: "run_at") var runAt: Date?
    @OptionalField(key: "last_run_at") var lastRunAt: Date?
    @OptionalField(key: "last_status") var lastStatus: String?
    @OptionalField(key: "last_error") var lastError: String?
    /// HER-247 — per-skill APNS category override ("digest" / "nudge" / "chat" / nil).
    @OptionalField(key: "apns_category") var apnsCategory: String?
    @OptionalField(key: "domain") var domain: String?
    @OptionalField(key: "space_id") var spaceID: UUID?
    /// Set once this legacy scheduled skill has been represented by an
    /// Automation 2.0 workflow. CronScheduler then leaves delivery to the
    /// workflow scheduler, preventing double execution during migration.
    @OptionalField(key: "workflow_id") var workflowID: UUID?

    init() {}

    init(
        tenantID: UUID,
        source: String,
        name: String,
        enabled: Bool = true,
        scheduleOverride: String? = nil,
        runAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastStatus: String? = nil,
        lastError: String? = nil,
        apnsCategory: String? = nil
    ) {
        id = tenantID
        self.tenantID = tenantID
        self.source = source
        self.name = name
        self.enabled = enabled
        self.scheduleOverride = scheduleOverride
        self.runAt = runAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.apnsCategory = apnsCategory
    }
}
