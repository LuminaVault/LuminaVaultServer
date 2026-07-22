import FluentKit
import Foundation
import LuminaVaultShared

final class ImprovementChange: Model, TenantModel, @unchecked Sendable {
    static let schema = "self_improvement_changes"

    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @OptionalField(key: "run_id") var runID: UUID?
    @Field(key: "kind") var kind: String
    @Field(key: "state") var state: String
    @Field(key: "trigger") var trigger: String
    @Field(key: "title") var title: String
    @Field(key: "summary") var summary: String
    @OptionalField(key: "patch") var patch: String?
    @OptionalField(key: "proposed_markdown") var proposedMarkdown: String?
    @OptionalField(key: "base_sha256") var baseSHA256: String?
    @OptionalField(key: "report_markdown") var reportMarkdown: String?
    @OptionalField(key: "failure_reason") var failureReason: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "applied_at") var appliedAt: Date?

    init() {}

    func toDTO() throws -> ImprovementChangeDTO {
        try ImprovementChangeDTO(
            id: requireID(),
            kind: ImprovementChangeKind(rawValue: kind) ?? .soul,
            state: ImprovementChangeState(rawValue: state) ?? .failed,
            trigger: ImprovementTrigger(rawValue: trigger) ?? .manual,
            title: title,
            summary: summary,
            patch: patch,
            baseSHA256: baseSHA256,
            reportMarkdown: reportMarkdown,
            failureReason: failureReason,
            createdAt: createdAt ?? Date(),
            decidedAt: decidedAt,
            appliedAt: appliedAt
        )
    }
}
