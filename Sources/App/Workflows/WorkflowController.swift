import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared

extension WorkflowListResponse: @retroactive ResponseEncodable {}
extension WorkflowDetailDTO: @retroactive ResponseEncodable {}
extension WorkflowRunDTO: @retroactive ResponseEncodable {}
extension WorkflowRunsResponse: @retroactive ResponseEncodable {}
extension WorkflowApprovalsResponse: @retroactive ResponseEncodable {}
extension WorkflowRunEventsResponse: @retroactive ResponseEncodable {}
extension WorkflowVersionsResponse: @retroactive ResponseEncodable {}
extension WorkflowValidationResponse: @retroactive ResponseEncodable {}
extension WorkflowTemplatesResponse: @retroactive ResponseEncodable {}
extension WorkflowLimitsDTO: @retroactive ResponseEncodable {}

struct WorkflowController {
    let service: WorkflowService
    let webhookController: WorkflowWebhookController
    let eventStore: WorkflowEventStore

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list); router.post("", use: create)
        router.post("/validate", use: validate); router.get("/limits", use: limits)
        router.get("/runs", use: allRuns); router.get("/approvals", use: approvals)
        router.get("/runs/:runID", use: runDetail)
        router.get("/runs/:runID/events", use: runEvents)
        router.get("/runs/:runID/events/stream", use: runEventStream)
        router.post("/runs/:runID/cancel", use: cancel)
        router.post("/runs/:runID/retry", use: retry)
        router.post("/runs/:runID/resume", use: resume)
        router.post("/approvals/:approvalID/decision", use: decide)
        router.get("/:id", use: detail); router.put("/:id/draft", use: update)
        router.post("/:id/publish", use: publish); router.post("/:id/runs", use: run)
        router.post("/:id/webhook/rotate", use: rotateWebhook)
        router.get("/:id/runs", use: workflowRuns)
        router.get("/:id/versions", use: versions)
        router.post("/:id/versions/:version/restore", use: restore)
    }

    @Sendable func rotateWebhook(_: Request, ctx: AppRequestContext) async throws -> WorkflowWebhookCredentialDTO {
        try await mapErrors {
            try await service.requireAuthorAccess(tenantID: ctx.requireTenantID())
            return try await webhookController.rotate(tenantID: ctx.requireTenantID(), workflowID: pathID(ctx, "id"))
        }
    }

    @Sendable func validate(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowValidationResponse {
        let body = try await req.decode(as: WorkflowDefinitionDTO.self, context: ctx)
        return try await service.validateDefinition(tenantID: ctx.requireTenantID(), definition: body)
    }

    @Sendable func limits(_: Request, ctx: AppRequestContext) async throws -> WorkflowLimitsDTO {
        try await service.limits(tenantID: ctx.requireTenantID())
    }

    @Sendable func list(_: Request, ctx: AppRequestContext) async throws -> WorkflowListResponse {
        try await service.list(tenantID: ctx.requireTenantID())
    }

    @Sendable func create(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        let body = try await req.decode(as: WorkflowCreateRequest.self, context: ctx)
        return try await mapErrors { try await service.create(tenantID: ctx.requireTenantID(), request: body) }
    }

    @Sendable func detail(_: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        try await mapErrors { try await service.detail(tenantID: ctx.requireTenantID(), id: pathID(ctx, "id")) }
    }

    @Sendable func update(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        let body = try await req.decode(as: WorkflowDraftUpdateRequest.self, context: ctx)
        return try await mapErrors { try await service.update(tenantID: ctx.requireTenantID(), id: pathID(ctx, "id"), request: body) }
    }

    @Sendable func publish(_: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        try await mapErrors { try await service.publish(tenantID: ctx.requireTenantID(), id: pathID(ctx, "id")) }
    }

    @Sendable func run(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        let body = try await req.decode(as: WorkflowRunRequest.self, context: ctx)
        return try await mapErrors { try await service.enqueue(tenantID: ctx.requireTenantID(), workflowID: pathID(ctx, "id"), trigger: .manual, request: body) }
    }

    @Sendable func allRuns(_: Request, ctx: AppRequestContext) async throws -> WorkflowRunsResponse {
        try await service.runs(tenantID: ctx.requireTenantID(), workflowID: nil)
    }

    @Sendable func workflowRuns(_: Request, ctx: AppRequestContext) async throws -> WorkflowRunsResponse {
        try await service.runs(tenantID: ctx.requireTenantID(), workflowID: pathID(ctx, "id"))
    }

    @Sendable func runDetail(_: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        try await mapErrors { try await service.run(tenantID: ctx.requireTenantID(), runID: pathID(ctx, "runID")) }
    }

    @Sendable func runEvents(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowRunEventsResponse {
        let after = req.uri.queryParameters.get("after").flatMap(Int64.init) ?? 0
        return try await mapErrors {
            try await service.eventList(tenantID: ctx.requireTenantID(), runID: pathID(ctx, "runID"), after: after)
        }
    }

    @Sendable func runEventStream(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowEventsSSEResponse {
        let tenantID = try ctx.requireTenantID()
        let runID = try pathID(ctx, "runID")
        _ = try await mapErrors { try await service.run(tenantID: tenantID, runID: runID) }
        let headerName = HTTPField.Name("last-event-id")
        let headerCursor = headerName.flatMap { req.headers[$0] }.flatMap(Int64.init)
        let queryCursor = req.uri.queryParameters.get("after").flatMap(Int64.init)
        return WorkflowEventsSSEResponse(
            store: eventStore,
            tenantID: tenantID,
            runID: runID,
            after: headerCursor ?? queryCursor ?? 0,
            isTerminal: { tenantID, runID in await service.isTerminal(tenantID: tenantID, runID: runID) }
        )
    }

    @Sendable func retry(_: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        try await mapErrors { try await service.retry(tenantID: ctx.requireTenantID(), runID: pathID(ctx, "runID")) }
    }

    @Sendable func resume(_: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        try await mapErrors { try await service.resume(tenantID: ctx.requireTenantID(), runID: pathID(ctx, "runID")) }
    }

    @Sendable func versions(_: Request, ctx: AppRequestContext) async throws -> WorkflowVersionsResponse {
        try await mapErrors { try await service.versions(tenantID: ctx.requireTenantID(), workflowID: pathID(ctx, "id")) }
    }

    @Sendable func restore(_: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        guard let raw = ctx.parameters.get("version"), let version = Int(raw), version > 0 else {
            throw HTTPError(.badRequest, message: "invalid_version")
        }
        return try await mapErrors {
            try await service.restore(tenantID: ctx.requireTenantID(), workflowID: pathID(ctx, "id"), version: version)
        }
    }

    @Sendable func approvals(_: Request, ctx: AppRequestContext) async throws -> WorkflowApprovalsResponse {
        try await service.approvals(tenantID: ctx.requireTenantID())
    }

    @Sendable func cancel(_: Request, ctx: AppRequestContext) async throws -> Response {
        try await mapErrors {
            try await service.cancel(tenantID: ctx.requireTenantID(), runID: pathID(ctx, "runID"))
        }
        return Response(status: .noContent)
    }

    @Sendable func decide(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let body = try await req.decode(as: WorkflowApprovalDecisionRequest.self, context: ctx)
        try await mapErrors { try await service.decide(tenantID: ctx.requireTenantID(), approvalID: pathID(ctx, "approvalID"), request: body) }
        return Response(status: .noContent)
    }

    private func pathID(_ ctx: AppRequestContext, _ name: String) throws -> UUID {
        guard let raw = ctx.parameters.get(name), let id = UUID(uuidString: raw) else { throw HTTPError(.badRequest, message: "invalid_\(name)") }
        return id
    }

    private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch WorkflowServiceError.notFound { throw HTTPError(.notFound, message: "workflow_not_found") }
        catch WorkflowServiceError.revisionConflict { throw HTTPError(.conflict, message: "workflow_revision_conflict") }
        catch WorkflowServiceError.unpublished { throw HTTPError(.conflict, message: "workflow_not_published") }
        catch WorkflowServiceError.forbidden { throw HTTPError(.forbidden, message: "workflow_access_denied") }
        catch WorkflowServiceError.activeRunLimit { throw HTTPError(.tooManyRequests, message: "workflow_active_run_limit") }
        catch let WorkflowServiceError.invalid(reason) { throw HTTPError(.badRequest, message: "invalid_workflow:\(reason)") }
    }
}

struct WorkflowTemplateController {
    let service: WorkflowService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("/:templateID/instantiate", use: instantiate)
        router.post("/:templateID/runs", use: run)
    }

    @Sendable func list(_: Request, ctx: AppRequestContext) async throws -> WorkflowTemplatesResponse {
        try await mapErrors {
            try await service.templates(tenantID: ctx.requireTenantID())
        }
    }

    @Sendable func instantiate(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowDetailDTO {
        let body = try await req.decode(as: WorkflowTemplateInstantiateRequest.self, context: ctx)
        return try await mapErrors {
            try await service.instantiateTemplate(
                tenantID: ctx.requireTenantID(),
                templateID: templateID(ctx),
                name: body.name
            )
        }
    }

    @Sendable func run(_ req: Request, ctx: AppRequestContext) async throws -> WorkflowRunDTO {
        let body = try await req.decode(as: WorkflowRunRequest.self, context: ctx)
        return try await mapErrors {
            try await service.runTemplate(
                tenantID: ctx.requireTenantID(),
                templateID: templateID(ctx),
                request: body
            )
        }
    }

    private func templateID(_ ctx: AppRequestContext) throws -> String {
        guard let id = ctx.parameters.get("templateID"), id.isEmpty == false else {
            throw HTTPError(.badRequest, message: "invalid_template_id")
        }
        return id
    }

    private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch WorkflowServiceError.notFound { throw HTTPError(.notFound, message: "workflow_template_not_found") }
        catch WorkflowServiceError.forbidden { throw HTTPError(.forbidden, message: "workflow_access_denied") }
        catch WorkflowServiceError.activeRunLimit { throw HTTPError(.tooManyRequests, message: "workflow_active_run_limit") }
        catch let WorkflowServiceError.invalid(reason) { throw HTTPError(.badRequest, message: "invalid_workflow:\(reason)") }
    }
}
