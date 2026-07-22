import FluentKit
import Foundation
import LuminaVaultShared

final class ImprovementRun: Model, TenantModel, @unchecked Sendable {
    static let schema = "self_improvement_runs"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "kind") var kind: String
    @Field(key: "status") var status: String
    @Field(key: "trigger") var trigger: String
    @Field(key: "dry_run") var dryRun: Bool
    @OptionalField(key: "model_used") var modelUsed: String?
    @OptionalField(key: "report_markdown") var reportMarkdown: String?
    @OptionalField(key: "snapshot_json") var snapshotJSON: String?
    @Field(key: "actions_applied") var actionsApplied: Int
    @Field(key: "actions_skipped") var actionsSkipped: Int
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?
    @OptionalField(key: "failure_reason") var failureReason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        tenantID: UUID,
        kind: ImprovementChangeKind,
        trigger: ImprovementTrigger,
        dryRun: Bool,
        now: Date = Date()
    ) {
        self.tenantID = tenantID
        self.kind = kind.rawValue
        status = ImprovementRunStatus.queued.rawValue
        self.trigger = trigger.rawValue
        self.dryRun = dryRun
        actionsApplied = 0
        actionsSkipped = 0
        createdAt = now
    }

    func toDTO() throws -> ImprovementRunDTO {
        try ImprovementRunDTO(
            id: requireID(),
            kind: ImprovementChangeKind(rawValue: kind) ?? .curator,
            status: ImprovementRunStatus(rawValue: status) ?? .failed,
            trigger: ImprovementTrigger(rawValue: trigger) ?? .manual,
            dryRun: dryRun,
            modelUsed: modelUsed,
            reportMarkdown: reportMarkdown,
            actionsApplied: actionsApplied,
            actionsSkipped: actionsSkipped,
            startedAt: startedAt,
            endedAt: endedAt,
            createdAt: createdAt ?? Date(),
            failureReason: failureReason
        )
    }
}
