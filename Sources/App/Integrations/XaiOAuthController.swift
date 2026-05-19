import Foundation
import Hummingbird
import Logging

/// HER-240a — HTTP surface for the per-tenant xAI Grok OAuth flow.
/// Mounted under `/v1/integrations/xai` on the JWT-protected route group.
struct XaiOAuthController {
    let service: XaiOAuthService
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.get("/integrations/xai", use: status)
        group.post("/integrations/xai/start", use: start)
        group.post("/integrations/xai/complete", use: complete)
        group.delete("/integrations/xai", use: revoke)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> XaiStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await service.status(tenantID: tenantID)
        return XaiStatusResponse(
            connected: s.connected,
            tier: s.tier,
            xaiConnectedAt: s.xaiConnectedAt,
        )
    }

    @Sendable
    func start(_: Request, ctx: AppRequestContext) async throws -> XaiStartResponse {
        let tenantID = try ctx.requireTenantID()
        let result = try await service.start(tenantID: tenantID)
        return XaiStartResponse(
            sessionID: result.sessionID,
            authorizeURL: result.authorizeURL,
        )
    }

    @Sendable
    func complete(_ req: Request, ctx: AppRequestContext) async throws -> XaiStatusResponse {
        let body = try await req.decode(as: XaiCompleteRequest.self, context: ctx)
        guard !body.sessionID.isEmpty else {
            throw HTTPError(.badRequest, message: "sessionID required")
        }
        guard !body.callbackURL.isEmpty else {
            throw HTTPError(.badRequest, message: "callbackURL required")
        }
        do {
            let s = try await service.complete(sessionID: body.sessionID, callbackURL: body.callbackURL)
            return XaiStatusResponse(
                connected: s.connected,
                tier: s.tier,
                xaiConnectedAt: s.xaiConnectedAt,
            )
        } catch XaiOAuthError.sessionNotFound {
            throw HTTPError(.notFound, message: "session not found or expired")
        } catch XaiOAuthError.notYetImplemented {
            throw HTTPError(.notImplemented, message: "xai oauth backend not enabled")
        } catch let XaiOAuthError.backendFailed(reason) {
            logger.warning("xai oauth backend failed: \(reason)")
            throw HTTPError(.badGateway, message: "xai oauth backend failed")
        }
    }

    @Sendable
    func revoke(_: Request, ctx: AppRequestContext) async throws -> XaiStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await service.revoke(tenantID: tenantID)
        return XaiStatusResponse(
            connected: s.connected,
            tier: s.tier,
            xaiConnectedAt: s.xaiConnectedAt,
        )
    }
}
