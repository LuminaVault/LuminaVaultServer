import FluentKit
import Foundation

/// HER-179 — per-tenant APNS category opt-out. Schema in M43.
/// Absence of a row means all categories enabled.
final class ApnsCategoryPrefs: Model, @unchecked Sendable {
    static let schema = "apns_category_prefs"

    @ID(custom: "tenant_id", generatedBy: .user) var id: UUID?
    @Field(key: "chat_enabled") var chatEnabled: Bool
    @Field(key: "nudge_enabled") var nudgeEnabled: Bool
    @Field(key: "digest_enabled") var digestEnabled: Bool
    /// Phase 1 (M119) — Hermes run pushes: tool-call approvals and completions.
    @Field(key: "approval_enabled") var approvalEnabled: Bool
    @Field(key: "run_completed_enabled") var runCompletedEnabled: Bool
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(
        tenantID: UUID,
        chatEnabled: Bool = true,
        nudgeEnabled: Bool = true,
        digestEnabled: Bool = true,
        approvalEnabled: Bool = true,
        runCompletedEnabled: Bool = true
    ) {
        id = tenantID
        self.chatEnabled = chatEnabled
        self.nudgeEnabled = nudgeEnabled
        self.digestEnabled = digestEnabled
        self.approvalEnabled = approvalEnabled
        self.runCompletedEnabled = runCompletedEnabled
    }
}
