import Foundation
import Hummingbird

/// `/v1/me/hermes/cron` — list + manage the tenant's **Hermes** cron jobs
/// (TUI parity). Managed transport (docker exec) today; BYO transport added
/// behind the same routes. JWT-gated; gated on a managed container existing.
struct CronBridgeController {
    let service: CronBridgeService

    struct ConfigRequest: Decodable {
        let dashboardUrl: String
        let dashboardToken: String
    }

    struct PreviewRequest: Decodable { let text: String }

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get(use: list)
        router.post(use: create)
        router.post("preview", use: preview)
        router.put("config", use: setConfig)
        router.post(":id/pause", use: pause)
        router.post(":id/resume", use: resume)
        router.delete(":id", use: remove)
    }

    /// Natural language → a cron spec for the user to confirm (no write).
    @Sendable
    func preview(_ req: Request, ctx: AppRequestContext) async throws -> CronCreateSpec {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: PreviewRequest.self, context: ctx)
        guard let spec = await service.preview(tenantID: tenantID, text: body.text) else {
            throw HTTPError(.unprocessableContent, message: "not_a_schedulable_job")
        }
        return spec
    }

    /// Configure the BYO dashboard cron endpoint (URL + token), then return the
    /// now-listable jobs.
    @Sendable
    func setConfig(_ req: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: ConfigRequest.self, context: ctx)
        try await service.setBYOConfig(tenantID: tenantID, url: body.dashboardUrl, token: body.dashboardToken)
        return try await service.list(tenantID: tenantID)
    }

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        let tenantID = try ctx.requireTenantID()
        return try await service.list(tenantID: tenantID) // managed → BYO
    }

    @Sendable
    func create(_ req: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        let tenantID = try ctx.requireTenantID()
        let spec = try await req.decode(as: CronCreateSpec.self, context: ctx)
        guard !spec.schedule.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw HTTPError(.badRequest, message: "schedule_required")
        }
        return try await service.create(tenantID: tenantID, spec: spec) // managed → BYO
    }

    @Sendable
    func pause(_: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        try await mutate(ctx, "pause")
    }

    @Sendable
    func resume(_: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        try await mutate(ctx, "resume")
    }

    @Sendable
    func remove(_: Request, ctx: AppRequestContext) async throws -> HermesCronListResponse {
        try await mutate(ctx, "remove")
    }

    private func mutate(_ ctx: AppRequestContext, _ action: String) async throws -> HermesCronListResponse {
        let tenantID = try ctx.requireTenantID()
        guard let id = ctx.parameters.get("id"), !id.isEmpty else {
            throw HTTPError(.badRequest, message: "id_required")
        }
        return try await HermesCronListResponse(source: "managed", jobs: service.mutateManaged(tenantID: tenantID, action: action, id: id))
    }
}
