import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

enum WorkflowServiceError: Error {
    case notFound, revisionConflict, unpublished, invalid(String)
}

actor WorkflowService {
    private let fluent: Fluent
    init(fluent: Fluent) {
        self.fluent = fluent
    }

    func list(tenantID: UUID) async throws -> WorkflowListResponse {
        let rows = try await Workflow.query(on: fluent.db(), tenantID: tenantID).sort(\.$updatedAt, .descending).all()
        var summaries: [WorkflowSummaryDTO] = []
        for row in rows {
            try await summaries.append(summary(row))
        }
        return WorkflowListResponse(workflows: summaries)
    }

    func detail(tenantID: UUID, id: UUID) async throws -> WorkflowDetailDTO {
        let row = try await require(tenantID: tenantID, id: id)
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func create(tenantID: UUID, request: WorkflowCreateRequest) async throws -> WorkflowDetailDTO {
        try validate(request.definition)
        let row = Workflow(tenantID: tenantID, name: request.name.trimmingCharacters(in: .whitespacesAndNewlines), descriptionText: request.descriptionText, definition: request.definition)
        try await row.create(on: fluent.db())
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func update(tenantID: UUID, id: UUID, request: WorkflowDraftUpdateRequest) async throws -> WorkflowDetailDTO {
        try validate(request.definition)
        let row = try await require(tenantID: tenantID, id: id)
        guard row.draftRevision == request.expectedRevision else { throw WorkflowServiceError.revisionConflict }
        if let name = request.name {
            row.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let descriptionText = request.descriptionText {
            row.descriptionText = descriptionText
        }
        if let enabled = request.enabled {
            row.enabled = enabled
        }
        row.draftDefinition = request.definition
        row.draftRevision += 1
        try await row.save(on: fluent.db())
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func publish(tenantID: UUID, id: UUID) async throws -> WorkflowDetailDTO {
        let row = try await require(tenantID: tenantID, id: id)
        try validate(row.draftDefinition)
        let latest = try await WorkflowVersion.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$workflowID == id).sort(\.$version, .descending).first()
        let version = WorkflowVersion()
        version.id = UUID(); version.tenantID = tenantID; version.workflowID = id
        version.version = (latest?.version ?? 0) + 1; version.definition = row.draftDefinition
        try await version.create(on: fluent.db())
        row.publishedVersionID = try version.requireID()
        try await row.save(on: fluent.db())
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func enqueue(tenantID: UUID, workflowID: UUID, trigger: WorkflowTriggerKind, request: WorkflowRunRequest) async throws -> WorkflowRunDTO {
        let workflow = try await require(tenantID: tenantID, id: workflowID)
        guard workflow.enabled, let versionID = workflow.publishedVersionID else { throw WorkflowServiceError.unpublished }
        let run = WorkflowRun()
        run.id = UUID(); run.tenantID = tenantID; run.workflowID = workflowID; run.versionID = versionID
        run.status = WorkflowRunStatus.queued.rawValue; run.triggerKind = trigger.rawValue
        run.input = request.input; run.conversationID = request.conversationID
        try await run.create(on: fluent.db())
        return try await runDTO(run, workflow: workflow)
    }

    func runs(tenantID: UUID, workflowID: UUID?) async throws -> WorkflowRunsResponse {
        var query = WorkflowRun.query(on: fluent.db(), tenantID: tenantID).sort(\.$createdAt, .descending).limit(100)
        if let workflowID {
            query = query.filter(\.$workflowID == workflowID)
        }
        let rows = try await query.all()
        var result: [WorkflowRunDTO] = []
        for row in rows {
            guard let workflow = try await Workflow.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == row.workflowID).first() else { continue }
            try await result.append(runDTO(row, workflow: workflow))
        }
        return WorkflowRunsResponse(runs: result)
    }

    func cancel(tenantID: UUID, runID: UUID) async throws {
        guard let run = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first()
        else { throw WorkflowServiceError.notFound }
        let terminal = [WorkflowRunStatus.succeeded, .failed, .cancelled, .timedOut].map(\.rawValue)
        guard !terminal.contains(run.status) else { return }
        run.status = WorkflowRunStatus.cancelled.rawValue
        run.endedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
        try await run.save(on: fluent.db())
        let nodes = try await WorkflowNodeRun.query(on: fluent.db())
            .filter(\.$runID == runID)
            .group(.or) { group in
                group.filter(\.$status == WorkflowNodeRunStatus.pending.rawValue)
                group.filter(\.$status == WorkflowNodeRunStatus.running.rawValue)
                group.filter(\.$status == WorkflowNodeRunStatus.waitingForApproval.rawValue)
            }.all()
        for node in nodes {
            node.status = WorkflowNodeRunStatus.cancelled.rawValue; node.endedAt = Date()
            try await node.save(on: fluent.db())
        }
    }

    func approvals(tenantID: UUID) async throws -> WorkflowApprovalsResponse {
        let rows = try await WorkflowApproval.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$status == "pending").sort(\.$createdAt, .descending).all()
        var values: [WorkflowApprovalDTO] = []
        for row in rows {
            guard let workflow = try await Workflow.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == row.workflowID).first() else { continue }
            try values.append(WorkflowApprovalDTO(id: row.requireID(), runID: row.runID, workflowID: row.workflowID, workflowName: workflow.name, nodeID: row.nodeID, title: row.title, message: row.message, expiresAt: row.expiresAt, createdAt: row.createdAt ?? Date()))
        }
        return WorkflowApprovalsResponse(approvals: values)
    }

    func decide(tenantID: UUID, approvalID: UUID, request: WorkflowApprovalDecisionRequest) async throws {
        guard let approval = try await WorkflowApproval.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == approvalID).first() else { throw WorkflowServiceError.notFound }
        guard approval.status == "pending" else { return }
        approval.status = request.approved ? "approved" : "rejected"; approval.decisionNote = request.note
        try await approval.save(on: fluent.db())
        guard let run = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == approval.runID).first() else { return }
        if let nodeRun = try await WorkflowNodeRun.query(on: fluent.db()).filter(\.$runID == approval.runID).filter(\.$nodeID == approval.nodeID).first() {
            nodeRun.status = request.approved ? WorkflowNodeRunStatus.succeeded.rawValue : WorkflowNodeRunStatus.failed.rawValue
            nodeRun.outputSnapshot = ["approved": request.approved ? "true" : "false", "note": request.note ?? ""]
            nodeRun.endedAt = Date(); try await nodeRun.save(on: fluent.db())
        }
        run.status = request.approved ? WorkflowRunStatus.queued.rawValue : WorkflowRunStatus.failed.rawValue
        run.errorMessage = request.approved ? nil : "Approval rejected"
        if !request.approved {
            run.endedAt = Date()
        }
        try await run.save(on: fluent.db())
    }

    private func require(tenantID: UUID, id: UUID) async throws -> Workflow {
        guard let row = try await Workflow.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == id).first() else { throw WorkflowServiceError.notFound }
        return row
    }

    private func validate(_ definition: WorkflowDefinitionDTO) throws {
        do { try WorkflowValidator.validate(definition) } catch { throw WorkflowServiceError.invalid(String(describing: error)) }
    }

    private func summary(_ row: Workflow) async throws -> WorkflowSummaryDTO {
        let id = try row.requireID()
        let version: Int? = if let versionID = row.publishedVersionID {
            try await WorkflowVersion.find(versionID, on: fluent.db())?.version
        } else {
            nil
        }
        let last = try await WorkflowRun.query(on: fluent.db(), tenantID: row.tenantID).filter(\.$workflowID == id).sort(\.$createdAt, .descending).first()
        let approvals = try await WorkflowApproval.query(on: fluent.db(), tenantID: row.tenantID).filter(\.$workflowID == id).filter(\.$status == "pending").count()
        return WorkflowSummaryDTO(id: id, name: row.name, descriptionText: row.descriptionText, enabled: row.enabled, trigger: row.draftDefinition.trigger, draftRevision: row.draftRevision, publishedVersion: version, lastRunStatus: last.flatMap { WorkflowRunStatus(rawValue: $0.status) }, lastRunAt: last?.startedAt ?? last?.createdAt, pendingApprovalCount: approvals, isLegacyJob: row.isLegacyJob, createdAt: row.createdAt ?? Date(), updatedAt: row.updatedAt ?? Date())
    }

    private func runDTO(_ row: WorkflowRun, workflow: Workflow) async throws -> WorkflowRunDTO {
        let version = try await WorkflowVersion.find(row.versionID, on: fluent.db())?.version ?? 0
        let nodes = try await WorkflowNodeRun.query(on: fluent.db()).filter(\.$runID == row.requireID()).sort(\.$createdAt, .ascending).all()
        return try WorkflowRunDTO(id: row.requireID(), workflowID: row.workflowID, workflowName: workflow.name, version: version, status: WorkflowRunStatus(rawValue: row.status) ?? .failed, trigger: WorkflowTriggerKind(rawValue: row.triggerKind) ?? .manual, startedAt: row.startedAt, endedAt: row.endedAt, createdAt: row.createdAt ?? Date(), error: row.errorMessage, nodeRuns: nodes.map { node in WorkflowNodeRunDTO(id: node.id ?? UUID(), nodeID: node.nodeID, nodeName: node.nodeName, status: WorkflowNodeRunStatus(rawValue: node.status) ?? .failed, attempt: node.attempt, startedAt: node.startedAt, endedAt: node.endedAt, outputPreview: node.outputSnapshot?["text"], error: node.errorMessage) })
    }
}
