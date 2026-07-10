import FluentKit
import Foundation
import LuminaVaultShared

/// Fluent requires reference-semantic models. Instances stay within the
/// WorkflowService/WorkflowEngine isolation boundary.
final class Workflow: Model, TenantModel, @unchecked Sendable {
    static let schema = "workflows"
    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "name") var name: String
    @OptionalField(key: "description_text") var descriptionText: String?
    @Field(key: "enabled") var enabled: Bool
    @Field(key: "draft_definition") var draftDefinition: WorkflowDefinitionDTO
    @Field(key: "draft_revision") var draftRevision: Int
    @OptionalField(key: "published_version_id") var publishedVersionID: UUID?
    @Field(key: "is_legacy_job") var isLegacyJob: Bool
    @OptionalField(key: "legacy_skill_name") var legacySkillName: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(tenantID: UUID, name: String, descriptionText: String?, definition: WorkflowDefinitionDTO, isLegacyJob: Bool = false, legacySkillName: String? = nil) {
        id = UUID(); self.tenantID = tenantID; self.name = name
        self.descriptionText = descriptionText; enabled = true
        draftDefinition = definition; draftRevision = 1
        self.isLegacyJob = isLegacyJob; self.legacySkillName = legacySkillName
    }
}

final class WorkflowVersion: Model, TenantModel, @unchecked Sendable {
    static let schema = "workflow_versions"
    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "workflow_id") var workflowID: UUID
    @Field(key: "version") var version: Int
    @Field(key: "definition") var definition: WorkflowDefinitionDTO
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class WorkflowRun: Model, TenantModel, @unchecked Sendable {
    static let schema = "workflow_runs"
    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "workflow_id") var workflowID: UUID
    @Field(key: "version_id") var versionID: UUID
    @Field(key: "status") var status: String
    @Field(key: "trigger_kind") var triggerKind: String
    @Field(key: "input") var input: [String: String]
    @OptionalField(key: "conversation_id") var conversationID: UUID?
    @OptionalField(key: "dedupe_key") var dedupeKey: String?
    @OptionalField(key: "lease_owner") var leaseOwner: String?
    @OptionalField(key: "lease_expires_at") var leaseExpiresAt: Date?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?
    @OptionalField(key: "error_message") var errorMessage: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
}

final class WorkflowNodeRun: Model, @unchecked Sendable {
    static let schema = "workflow_node_runs"
    @ID(key: .id) var id: UUID?
    @Field(key: "run_id") var runID: UUID
    @Field(key: "node_id") var nodeID: UUID
    @Field(key: "node_name") var nodeName: String
    @Field(key: "status") var status: String
    @Field(key: "attempt") var attempt: Int
    @OptionalField(key: "input_snapshot") var inputSnapshot: [String: String]?
    @OptionalField(key: "output_snapshot") var outputSnapshot: [String: String]?
    @OptionalField(key: "error_message") var errorMessage: String?
    @OptionalField(key: "started_at") var startedAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
}

final class WorkflowApproval: Model, TenantModel, @unchecked Sendable {
    static let schema = "workflow_approvals"
    @ID(key: .id) var id: UUID?
    @Field(key: "tenant_id") var tenantID: UUID
    @Field(key: "run_id") var runID: UUID
    @Field(key: "workflow_id") var workflowID: UUID
    @Field(key: "node_id") var nodeID: UUID
    @Field(key: "title") var title: String
    @OptionalField(key: "message") var message: String?
    @Field(key: "status") var status: String
    @OptionalField(key: "decision_note") var decisionNote: String?
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
}
