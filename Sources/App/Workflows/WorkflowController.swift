import Foundation
import Hummingbird
import LuminaVaultShared

extension WorkflowListResponse: @retroactive ResponseEncodable {}
extension WorkflowDetailDTO: @retroactive ResponseEncodable {}
extension WorkflowRunDTO: @retroactive ResponseEncodable {}
extension WorkflowRunsResponse: @retroactive ResponseEncodable {}
extension WorkflowApprovalsResponse: @retroactive ResponseEncodable {}

struct WorkflowController {
    let service: WorkflowService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list); router.post("", use: create)
        router.get("/runs", use: allRuns); router.get("/approvals", use: approvals)
        router.post("/runs/:runID/cancel", use: cancel)
        router.post("/approvals/:approvalID/decision", use: decide)
        router.get("/:id", use: detail); router.put("/:id/draft", use: update)
        router.post("/:id/publish", use: publish); router.post("/:id/runs", use: run)
        router.get("/:id/runs", use: workflowRuns)
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
        catch let WorkflowServiceError.invalid(reason) { throw HTTPError(.badRequest, message: "invalid_workflow:\(reason)") }
    }
}
