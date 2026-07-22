import Foundation
import Hummingbird
import LuminaVaultShared

extension ImprovementStatusDTO: ResponseEncodable {}
extension ImprovementRunDTO: ResponseEncodable {}
extension ImprovementRunsResponse: ResponseEncodable {}
extension ImprovementChangesResponse: ResponseEncodable {}
extension ImprovementDecisionResponse: ResponseEncodable {}
extension ImprovementSkillsResponse: ResponseEncodable {}
extension ImprovementSkillDTO: ResponseEncodable {}
extension ImprovementRollbackResponse: ResponseEncodable {}
extension ImprovementRunAcceptedResponse: ResponseEncodable {}

struct SelfImprovementController {
    let service: SelfImprovementService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: getStatus)
        router.put("", use: putSettings)
        router.post("/curator/runs", use: runCurator)
        router.get("/runs", use: listRuns)
        router.get("/runs/:id", use: getRun)
        router.post("/runs/:id/rollback", use: rollback)
        router.get("/resources", use: listResources)
        router.patch("/resources/:kind/:name", use: pinResource)
        router.post("/soul/reviews", use: reviewSoul)
        router.get("/changes", use: listChanges)
        router.post("/changes/:id/approve", use: approveChange)
        router.post("/changes/:id/reject", use: rejectChange)
    }

    @Sendable
    func getStatus(_: Request, ctx: AppRequestContext) async throws -> ImprovementStatusDTO {
        try await service.status(for: ctx.requireIdentity())
    }

    @Sendable
    func putSettings(_ req: Request, ctx: AppRequestContext) async throws -> ImprovementStatusDTO {
        let body = try await req.decode(as: ImprovementSettingsUpdateRequest.self, context: ctx)
        return try await service.updateSettings(body.settings, for: ctx.requireIdentity())
    }

    @Sendable
    func runCurator(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let body = await (try? req.decode(as: ImprovementRunRequest.self, context: ctx)) ?? ImprovementRunRequest()
        let run = try await service.enqueueCurator(for: ctx.requireIdentity(), trigger: .manual, dryRun: body.dryRun)
        return try await accepted(ImprovementRunAcceptedResponse(run: run), request: req, context: ctx)
    }

    @Sendable
    func reviewSoul(_ req: Request, ctx: AppRequestContext) async throws -> Response {
        let body = await (try? req.decode(as: SoulReviewRequest.self, context: ctx)) ?? SoulReviewRequest()
        guard body.trigger == .manual else { throw HTTPError(.badRequest, message: "manual_trigger_required") }
        let run = try await service.enqueueSoulReview(for: ctx.requireIdentity(), trigger: .manual)
        return try await accepted(ImprovementRunAcceptedResponse(run: run), request: req, context: ctx)
    }

    @Sendable
    func listRuns(_ req: Request, ctx: AppRequestContext) async throws -> ImprovementRunsResponse {
        let limit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? 50
        return try await service.runs(for: ctx.requireIdentity(), limit: limit)
    }

    @Sendable
    func getRun(_: Request, ctx: AppRequestContext) async throws -> ImprovementRunDTO {
        try await service.run(id: Self.id(ctx), for: ctx.requireIdentity())
    }

    @Sendable
    func rollback(_: Request, ctx: AppRequestContext) async throws -> ImprovementRollbackResponse {
        try await ImprovementRollbackResponse(run: service.rollback(runID: Self.id(ctx), for: ctx.requireIdentity()))
    }

    @Sendable
    func listResources(_: Request, ctx: AppRequestContext) async throws -> ImprovementSkillsResponse {
        try await service.resources(for: ctx.requireIdentity())
    }

    @Sendable
    func pinResource(_ req: Request, ctx: AppRequestContext) async throws -> ImprovementSkillDTO {
        guard let rawKind = ctx.parameters.get("kind"),
              let kind = ImprovementResourceKind(rawValue: rawKind),
              let name = ctx.parameters.get("name")
        else { throw HTTPError(.badRequest, message: "invalid_resource") }
        let body = try await req.decode(as: ImprovementSkillPinRequest.self, context: ctx)
        return try await service.setPinned(body.pinned, kind: kind, name: name, for: ctx.requireIdentity())
    }

    @Sendable
    func listChanges(_: Request, ctx: AppRequestContext) async throws -> ImprovementChangesResponse {
        try await service.changes(for: ctx.requireIdentity())
    }

    @Sendable
    func approveChange(_: Request, ctx: AppRequestContext) async throws -> ImprovementDecisionResponse {
        try await ImprovementDecisionResponse(change: service.decide(changeID: Self.id(ctx), approve: true, for: ctx.requireIdentity()))
    }

    @Sendable
    func rejectChange(_: Request, ctx: AppRequestContext) async throws -> ImprovementDecisionResponse {
        try await ImprovementDecisionResponse(change: service.decide(changeID: Self.id(ctx), approve: false, for: ctx.requireIdentity()))
    }

    private func accepted(
        _ body: some ResponseEncodable,
        request: Request,
        context: AppRequestContext
    ) async throws -> Response {
        var response = try body.response(from: request, context: context)
        response.status = .accepted
        return response
    }

    private static func id(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid_id")
        }
        return id
    }
}
