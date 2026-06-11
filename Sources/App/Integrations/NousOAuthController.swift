import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

// Wire DTOs live in LuminaVaultShared; Hummingbird response conformance is
// added here retroactively (shared can't depend on Hummingbird). Mirrors the
// `AppleConsentResponse` pattern.
extension NousStatusResponse: @retroactive ResponseEncodable {}
extension NousStartResponse: @retroactive ResponseEncodable {}

/// Nous Subscription Integration — HTTP surface for the per-tenant Nous Portal
/// OAuth device-code flow. Mounted under `/v1/integrations/nous` on the
/// JWT-protected route group, alongside `XaiOAuthController`.
struct NousOAuthController {
    let service: NousOAuthService
    let logger: Logger

    func addRoutes(to group: RouterGroup<AppRequestContext>) {
        group.get("/integrations/nous", use: status)
        group.post("/integrations/nous/start", use: start)
        group.post("/integrations/nous/complete", use: complete)
        group.delete("/integrations/nous", use: revoke)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> NousStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await service.status(tenantID: tenantID)
        return NousStatusResponse(
            connected: s.connected,
            nousConnectedAt: s.nousConnectedAt,
            plan: s.plan
        )
    }

    @Sendable
    func start(_: Request, ctx: AppRequestContext) async throws -> NousStartResponse {
        let tenantID = try ctx.requireTenantID()
        do {
            let result = try await service.start(tenantID: tenantID)
            return NousStartResponse(
                sessionID: result.sessionID,
                verifyURL: result.verifyURL,
                userCode: result.userCode
            )
        } catch NousOAuthError.verifyURLMissingFromStdout {
            throw HTTPError(.badGateway, message: "nous oauth backend did not return a verification URL")
        } catch NousOAuthError.notYetImplemented {
            throw HTTPError(.notImplemented, message: "nous oauth backend not enabled")
        }
    }

    @Sendable
    func complete(_ req: Request, ctx: AppRequestContext) async throws -> NousStatusResponse {
        let body = try await req.decode(as: NousCompleteRequest.self, context: ctx)
        guard !body.sessionID.isEmpty else {
            throw HTTPError(.badRequest, message: "sessionID required")
        }
        do {
            let s = try await service.complete(sessionID: body.sessionID)
            return NousStatusResponse(
                connected: s.connected,
                nousConnectedAt: s.nousConnectedAt,
                plan: s.plan
            )
        } catch NousOAuthError.sessionNotFound {
            throw HTTPError(.notFound, message: "session not found or expired")
        } catch let NousOAuthError.backendFailed(reason) {
            logger.warning("nous oauth backend failed: \(reason)")
            throw HTTPError(.badGateway, message: "nous oauth backend failed")
        }
    }

    @Sendable
    func revoke(_: Request, ctx: AppRequestContext) async throws -> NousStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await service.revoke(tenantID: tenantID)
        return NousStatusResponse(
            connected: s.connected,
            nousConnectedAt: s.nousConnectedAt,
            plan: s.plan
        )
    }
}
