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
///
/// `tenant_id` is the Fluent `@ID` only — never also `@Field(key: "tenant_id")`
/// or INSERTs emit the column twice (Postgres 42701).
final class SkillsState: Model, TenantModel, @unchecked Sendable {
    static let schema = "skills_state"

    @ID(custom: "tenant_id", generatedBy: .user) var id: UUID?
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
    @Field(key: "curator_pinned") var curatorPinned: Bool
    @Field(key: "curator_state") var curatorState: String
    @OptionalField(key: "curator_last_activity_at") var curatorLastActivityAt: Date?
    @OptionalField(key: "curator_archived_at") var curatorArchivedAt: Date?

    /// `TenantModel` surface — same column as `@ID`. Query with `\.$id`, not `\.$tenantID`.
    var tenantID: UUID {
        get {
            guard let id else {
                preconditionFailure("SkillsState.tenantID read before id was set")
            }
            return id
        }
        set { id = newValue }
    }

    init() {
        curatorPinned = false
        curatorState = "active"
    }

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
        self.source = source
        self.name = name
        self.enabled = enabled
        self.scheduleOverride = scheduleOverride
        self.runAt = runAt
        self.lastRunAt = lastRunAt
        self.lastStatus = lastStatus
        self.lastError = lastError
        self.apnsCategory = apnsCategory
        curatorPinned = false
        curatorState = "active"
    }
}
