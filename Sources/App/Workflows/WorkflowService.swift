import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import LuminaVaultShared

enum WorkflowServiceError: Error {
    case notFound, revisionConflict, unpublished, forbidden, activeRunLimit, invalid(String)
}

actor WorkflowService {
    private let fluent: Fluent
    private let spend: WorkflowSpendService?
    private let events: WorkflowEventStore?

    init(fluent: Fluent, spend: WorkflowSpendService? = nil, events: WorkflowEventStore? = nil) {
        self.fluent = fluent
        self.spend = spend
        self.events = events
    }

    func list(tenantID: UUID) async throws -> WorkflowListResponse {
        try await requireReadAccess(tenantID: tenantID)
        let rows = try await Workflow.query(on: fluent.db(), tenantID: tenantID).sort(\.$updatedAt, .descending).all()
        var summaries: [WorkflowSummaryDTO] = []
        for row in rows {
            try await summaries.append(summary(row))
        }
        return WorkflowListResponse(workflows: summaries)
    }

    func detail(tenantID: UUID, id: UUID) async throws -> WorkflowDetailDTO {
        try await requireReadAccess(tenantID: tenantID)
        let row = try await require(tenantID: tenantID, id: id)
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func create(tenantID: UUID, request: WorkflowCreateRequest) async throws -> WorkflowDetailDTO {
        let tier = try await requireAuthorTier(tenantID: tenantID)
        try validate(request.definition, tier: tier)
        let row = Workflow(tenantID: tenantID, name: request.name.trimmingCharacters(in: .whitespacesAndNewlines), descriptionText: request.descriptionText, definition: request.definition)
        try await row.create(on: fluent.db())
        return try await WorkflowDetailDTO(workflow: summary(row), definition: row.draftDefinition)
    }

    func update(tenantID: UUID, id: UUID, request: WorkflowDraftUpdateRequest) async throws -> WorkflowDetailDTO {
        let tier = try await requireAuthorTier(tenantID: tenantID)
        try validate(request.definition, tier: tier)
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
        let tier = try await requireAuthorTier(tenantID: tenantID)
        let row = try await require(tenantID: tenantID, id: id)
        try validate(row.draftDefinition, tier: tier)
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

    func enqueue(tenantID: UUID, workflowID: UUID, trigger: WorkflowTriggerKind, request: WorkflowRunRequest, dedupeKey: String? = nil) async throws -> WorkflowRunDTO {
        let tier = try await requireAuthorTier(tenantID: tenantID)
        let workflow = try await require(tenantID: tenantID, id: workflowID)
        guard workflow.enabled, let versionID = workflow.publishedVersionID else { throw WorkflowServiceError.unpublished }

        // Idempotency must be resolved before admission control. A retried
        // webhook or scheduler delivery is not a new active run and must still
        // return the original response when the tenant is at its run limit.
        if let dedupeKey,
           let existing = try await existingRun(tenantID: tenantID, workflowID: workflowID, dedupeKey: dedupeKey)
        {
            WorkflowMetrics.deduplicated.increment()
            return try await runDTO(existing, workflow: workflow)
        }

        let policy: WorkflowTierPolicy
        if let spend {
            do {
                policy = try await spend.ensureCanEnqueue(tenantID: tenantID, tier: tier)
            } catch WorkflowSpendError.activeRunLimit {
                // Another delivery can win between the first idempotency read
                // and admission control. Re-read before reporting the limit.
                if let dedupeKey,
                   let existing = try await existingRun(tenantID: tenantID, workflowID: workflowID, dedupeKey: dedupeKey)
                {
                    WorkflowMetrics.deduplicated.increment()
                    return try await runDTO(existing, workflow: workflow)
                }
                throw WorkflowServiceError.activeRunLimit
            }
        } else {
            policy = WorkflowTierPolicy.policy(for: tier)
        }
        let run = WorkflowRun()
        run.id = UUID(); run.tenantID = tenantID; run.workflowID = workflowID; run.versionID = versionID
        run.status = WorkflowRunStatus.queued.rawValue; run.triggerKind = trigger.rawValue
        run.input = request.input; run.conversationID = request.conversationID
        run.dedupeKey = dedupeKey
        run.managedSpendUsdMicros = 0
        run.managedSpendLimitUsdMicros = policy.perRunUsdMicros
        do {
            try await run.create(on: fluent.db())
        } catch {
            // The partial unique index is the cross-process idempotency guard.
            // If a second replica won the insert, return its durable run.
            if let databaseError = error as? any DatabaseError,
               databaseError.isConstraintFailure,
               let dedupeKey,
               let existing = try await existingRun(tenantID: tenantID, workflowID: workflowID, dedupeKey: dedupeKey)
            {
                WorkflowMetrics.deduplicated.increment()
                return try await runDTO(existing, workflow: workflow)
            }
            throw error
        }
        if let runID = run.id {
            await events?.append(tenantID: tenantID, runID: runID, kind: .runQueued)
        }
        WorkflowMetrics.queued.increment()
        return try await runDTO(run, workflow: workflow)
    }

    func runs(tenantID: UUID, workflowID: UUID?) async throws -> WorkflowRunsResponse {
        try await requireReadAccess(tenantID: tenantID)
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
        _ = try await requireAuthorTier(tenantID: tenantID)
        guard let run = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first()
        else { throw WorkflowServiceError.notFound }
        let terminal = [WorkflowRunStatus.succeeded, .failed, .cancelled, .timedOut].map(\.rawValue)
        guard !terminal.contains(run.status) else { return }
        run.status = WorkflowRunStatus.cancelled.rawValue
        run.endedAt = Date(); run.leaseOwner = nil; run.leaseExpiresAt = nil
        try await run.save(on: fluent.db())
        WorkflowMetrics.cancelled.increment()
        await events?.append(tenantID: tenantID, runID: runID, kind: .runCancelled)
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
        try await requireReadAccess(tenantID: tenantID)
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
        _ = try await requireAuthorTier(tenantID: tenantID)
        guard let approval = try await WorkflowApproval.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == approvalID).first() else { throw WorkflowServiceError.notFound }
        guard approval.status == "pending" else { return }
        approval.status = request.approved ? "approved" : "rejected"; approval.decisionNote = request.note
        approval.memoryIDs = request.memoryIDs ?? []
        try await approval.save(on: fluent.db())
        guard let run = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == approval.runID).first() else { return }
        if let nodeRun = try await WorkflowNodeRun.query(on: fluent.db()).filter(\.$runID == approval.runID).filter(\.$nodeID == approval.nodeID).first() {
            nodeRun.status = request.approved ? WorkflowNodeRunStatus.succeeded.rawValue : WorkflowNodeRunStatus.failed.rawValue
            var output = ["approved": request.approved ? "true" : "false", "note": request.note ?? ""]
            let attached = try await attachedMemories(tenantID: tenantID, ids: request.memoryIDs ?? [])
            if attached.isEmpty == false {
                output["memoryIDs"] = attached.map { $0.id?.uuidString ?? "" }.joined(separator: ",")
                output["attachedMemories"] = attached.map(\.content).joined(separator: "\n\n")
            }
            nodeRun.outputSnapshot = output
            nodeRun.endedAt = Date(); try await nodeRun.save(on: fluent.db())
        }
        run.status = request.approved ? WorkflowRunStatus.queued.rawValue : WorkflowRunStatus.failed.rawValue
        run.errorMessage = request.approved ? nil : "Approval rejected"
        if !request.approved {
            run.endedAt = Date()
        }
        try await run.save(on: fluent.db())
        await events?.append(
            tenantID: tenantID,
            runID: approval.runID,
            kind: request.approved ? .nodeCompleted : .runFailed,
            nodeID: approval.nodeID,
            message: request.approved ? "Approval granted" : "Approval rejected"
        )
    }

    func run(tenantID: UUID, runID: UUID) async throws -> WorkflowRunDTO {
        try await requireReadAccess(tenantID: tenantID)
        guard let row = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first(),
            let workflow = try await Workflow.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == row.workflowID).first()
        else { throw WorkflowServiceError.notFound }
        return try await runDTO(row, workflow: workflow)
    }

    func versions(tenantID: UUID, workflowID: UUID) async throws -> WorkflowVersionsResponse {
        try await requireReadAccess(tenantID: tenantID)
        _ = try await require(tenantID: tenantID, id: workflowID)
        let rows = try await WorkflowVersion.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$workflowID == workflowID)
            .sort(\.$version, .descending)
            .all()
        return try WorkflowVersionsResponse(versions: rows.map { row in
            try WorkflowVersionDTO(
                id: row.requireID(),
                workflowID: row.workflowID,
                version: row.version,
                definition: row.definition,
                createdAt: row.createdAt ?? .now
            )
        })
    }

    func restore(tenantID: UUID, workflowID: UUID, version: Int) async throws -> WorkflowDetailDTO {
        _ = try await requireAuthorTier(tenantID: tenantID)
        let workflow = try await require(tenantID: tenantID, id: workflowID)
        guard let snapshot = try await WorkflowVersion.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$workflowID == workflowID)
            .filter(\.$version == version)
            .first()
        else { throw WorkflowServiceError.notFound }
        workflow.draftDefinition = snapshot.definition
        workflow.draftRevision += 1
        try await workflow.save(on: fluent.db())
        return try await WorkflowDetailDTO(workflow: summary(workflow), definition: workflow.draftDefinition)
    }

    func validateDefinition(tenantID: UUID, definition: WorkflowDefinitionDTO) async -> WorkflowValidationResponse {
        do {
            let tier = try await requireAuthorTier(tenantID: tenantID)
            try validate(definition, tier: tier)
            return WorkflowValidationResponse(valid: true)
        } catch {
            return WorkflowValidationResponse(valid: false, issues: [
                WorkflowValidationIssueDTO(code: Self.validationCode(error), message: Self.validationMessage(error)),
            ])
        }
    }

    func limits(tenantID: UUID) async throws -> WorkflowLimitsDTO {
        let tier = try await effectiveTier(tenantID: tenantID)
        guard tier != .archived else { throw WorkflowServiceError.forbidden }
        if let spend {
            return await spend.limits(tenantID: tenantID, tier: tier)
        }
        let policy = WorkflowTierPolicy.policy(for: tier)
        return WorkflowLimitsDTO(
            tier: tier,
            canAuthor: policy.activeRunLimit > 0,
            activeRuns: 0,
            activeRunLimit: policy.activeRunLimit,
            minimumScheduleMinutes: policy.minimumScheduleMinutes,
            perRunLimitUsdMicros: policy.perRunUsdMicros,
            dailyLimitUsdMicros: policy.dailyUsdMicros,
            dailySpentUsdMicros: 0,
            monthlyLimitUsdMicros: policy.monthlyUsdMicros,
            monthlySpentUsdMicros: 0,
            managedInferenceAvailable: false,
            freeFallbackActive: true
        )
    }

    func eventList(tenantID: UUID, runID: UUID, after: Int64 = 0) async throws -> WorkflowRunEventsResponse {
        _ = try await run(tenantID: tenantID, runID: runID)
        return try await WorkflowRunEventsResponse(events: events?.list(tenantID: tenantID, runID: runID, after: after) ?? [])
    }

    func retry(tenantID: UUID, runID: UUID) async throws -> WorkflowRunDTO {
        guard let previous = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first()
        else { throw WorkflowServiceError.notFound }
        guard [WorkflowRunStatus.failed.rawValue, WorkflowRunStatus.timedOut.rawValue, WorkflowRunStatus.cancelled.rawValue, WorkflowRunStatus.paused.rawValue].contains(previous.status) else {
            throw WorkflowServiceError.invalid("run_not_retryable")
        }
        return try await enqueue(
            tenantID: tenantID,
            workflowID: previous.workflowID,
            trigger: WorkflowTriggerKind(rawValue: previous.triggerKind) ?? .manual,
            request: WorkflowRunRequest(input: previous.input, conversationID: previous.conversationID)
        )
    }

    func resume(tenantID: UUID, runID: UUID) async throws -> WorkflowRunDTO {
        let tier = try await requireAuthorTier(tenantID: tenantID)
        guard let row = try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first(), row.status == WorkflowRunStatus.paused.rawValue,
            let workflow = try await Workflow.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == row.workflowID).first()
        else { throw WorkflowServiceError.notFound }
        if let spend {
            do {
                _ = try await spend.ensureCanEnqueue(tenantID: tenantID, tier: tier)
            } catch WorkflowSpendError.activeRunLimit {
                throw WorkflowServiceError.activeRunLimit
            }
        }
        row.status = WorkflowRunStatus.queued.rawValue
        row.pauseReason = nil
        row.errorMessage = nil
        row.leaseOwner = nil
        row.leaseExpiresAt = nil
        try await row.save(on: fluent.db())
        await events?.append(tenantID: tenantID, runID: runID, kind: .runQueued, message: "Run resumed")
        return try await runDTO(row, workflow: workflow)
    }

    func templates(tenantID: UUID) async throws -> WorkflowTemplatesResponse {
        let tier = try await effectiveTier(tenantID: tenantID)
        guard tier != .archived else { throw WorkflowServiceError.forbidden }
        return WorkflowTemplatesResponse(templates: WorkflowTemplateCatalog.templates)
    }

    func instantiateTemplate(tenantID: UUID, templateID: String, name: String?) async throws -> WorkflowDetailDTO {
        guard let template = WorkflowTemplateCatalog.template(id: templateID) else { throw WorkflowServiceError.notFound }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName = trimmedName?.isEmpty == false ? trimmedName ?? template.name : template.name
        return try await create(
            tenantID: tenantID,
            request: WorkflowCreateRequest(
                name: effectiveName,
                descriptionText: template.descriptionText,
                definition: template.definition
            )
        )
    }

    func runTemplate(tenantID: UUID, templateID: String, request: WorkflowRunRequest) async throws -> WorkflowRunDTO {
        guard let template = WorkflowTemplateCatalog.template(id: templateID) else { throw WorkflowServiceError.notFound }
        let suffix = UUID().uuidString.prefix(8)
        let workflow = try await instantiateTemplate(
            tenantID: tenantID,
            templateID: templateID,
            name: "\(template.name) — \(suffix)"
        )
        _ = try await publish(tenantID: tenantID, id: workflow.workflow.id)
        return try await enqueue(tenantID: tenantID, workflowID: workflow.workflow.id, trigger: .manual, request: request)
    }

    func isTerminal(tenantID: UUID, runID: UUID) async -> Bool {
        guard let run = try? await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == runID).first()
        else { return true }
        return [WorkflowRunStatus.succeeded, .failed, .cancelled, .timedOut, .paused]
            .map(\.rawValue).contains(run.status)
    }

    func requireAuthorAccess(tenantID: UUID) async throws {
        _ = try await requireAuthorTier(tenantID: tenantID)
    }

    private func require(tenantID: UUID, id: UUID) async throws -> Workflow {
        guard let row = try await Workflow.query(on: fluent.db(), tenantID: tenantID).filter(\.$id == id).first() else { throw WorkflowServiceError.notFound }
        return row
    }

    private func existingRun(tenantID: UUID, workflowID: UUID, dedupeKey: String) async throws -> WorkflowRun? {
        try await WorkflowRun.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$workflowID == workflowID)
            .filter(\.$dedupeKey == dedupeKey)
            .first()
    }

    private func validate(_ definition: WorkflowDefinitionDTO, tier: UserTier) throws {
        do {
            try WorkflowValidator.validate(definition)
            try WorkflowSchedulePolicy.validate(definition: definition, minimumMinutes: WorkflowTierPolicy.policy(for: tier).minimumScheduleMinutes)
        } catch {
            throw WorkflowServiceError.invalid(String(describing: error))
        }
    }

    private func requireAuthorTier(tenantID: UUID) async throws -> UserTier {
        let tier = try await effectiveTier(tenantID: tenantID)
        guard tier == .pro || tier == .ultimate else { throw WorkflowServiceError.forbidden }
        return tier
    }

    private func requireReadAccess(tenantID: UUID) async throws {
        let tier = try await effectiveTier(tenantID: tenantID)
        guard tier == .pro || tier == .ultimate || tier == .lapsed else {
            throw WorkflowServiceError.forbidden
        }
    }

    private func effectiveTier(tenantID: UUID) async throws -> UserTier {
        guard let user = try await User.find(tenantID, on: fluent.db()) else { throw WorkflowServiceError.notFound }
        return EntitlementChecker.effectiveTier(tier: user.tierEnum, override: user.tierOverrideEnum)
    }

    private func attachedMemories(tenantID: UUID, ids: [UUID]) async throws -> [Memory] {
        guard ids.isEmpty == false else { return [] }
        let rows = try await Memory.query(on: fluent.db(), tenantID: tenantID).filter(\.$id ~~ ids).all()
        guard rows.count == Set(ids).count else { throw WorkflowServiceError.invalid("invalid_memory_attachment") }
        return rows
    }

    private static func validationCode(_ error: any Error) -> String {
        if let service = error as? WorkflowServiceError {
            switch service {
            case .forbidden: return "workflow_access_denied"
            case let .invalid(reason): return reason
            default: return "workflow_invalid"
            }
        }
        return String(describing: error)
    }

    private static func validationMessage(_ error: any Error) -> String {
        switch error {
        case WorkflowServiceError.forbidden:
            "A Pro or Ultimate plan is required to author workflows."
        default:
            "The workflow cannot be published until this issue is fixed: \(error)"
        }
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
        return try WorkflowRunDTO(
            id: row.requireID(),
            workflowID: row.workflowID,
            workflowName: workflow.name,
            version: version,
            status: WorkflowRunStatus(rawValue: row.status) ?? .failed,
            trigger: WorkflowTriggerKind(rawValue: row.triggerKind) ?? .manual,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            createdAt: row.createdAt ?? .now,
            error: row.errorMessage,
            pauseReason: row.pauseReason.flatMap(WorkflowPauseReason.init(rawValue:)),
            managedSpendUsdMicros: row.managedSpendUsdMicros,
            managedSpendLimitUsdMicros: row.managedSpendLimitUsdMicros,
            nodeRuns: nodes.map { node in
                WorkflowNodeRunDTO(
                    id: node.id ?? UUID(),
                    nodeID: node.nodeID,
                    nodeName: node.nodeName,
                    status: WorkflowNodeRunStatus(rawValue: node.status) ?? .failed,
                    attempt: node.attempt,
                    startedAt: node.startedAt,
                    endedAt: node.endedAt,
                    outputPreview: node.outputSnapshot?["text"],
                    error: node.errorMessage,
                    provider: node.selectedProvider.flatMap(ProviderID.init(rawValue:)),
                    model: node.selectedModel,
                    tokensIn: node.tokensIn.map(Int.init),
                    tokensOut: node.tokensOut.map(Int.init),
                    managedCostUsdMicros: node.managedCostUsdMicros
                )
            }
        )
    }
}
