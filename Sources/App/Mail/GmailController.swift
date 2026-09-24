import Foundation
import Hummingbird
import Logging
import LuminaVaultShared

extension GmailStatusResponse: @retroactive ResponseEncodable {}

/// Muse Chat stage C — "Connect Gmail" (read-only metadata).
///
/// Authed, mounted at `/v1/mail/gmail`:
/// - `GET  status`     — `GmailStatusResponse`.
/// - `POST connect`    — Google consent URL (`CalendarConnectStartResponse`)
///   asking for `gmail.readonly` incrementally on the Calendar OAuth client.
///   Web passes `?returnTo=` (an allowed web origin); iOS gets
///   `luminavault://oauth/google-gmail?status=ok|error&reason=…`.
/// - `POST disconnect` — stop reading mail (204).
///
/// The OAuth callback is the Calendar one (`/v1/calendar/oauth/callback`):
/// one Google client, one registered redirect URI; the session remembers
/// which Connect started the flow.
struct GmailController {
    let oauthService: GoogleCalendarOAuthService
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("status", use: status)
        router.post("connect", use: connect)
        router.post("disconnect", use: disconnect)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> GmailStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await oauthService.gmailStatus(tenantID: tenantID)
        return GmailStatusResponse(
            connected: s.connected,
            needsReauth: s.needsReauth,
            accountEmail: s.accountEmail,
            calendarConnected: s.calendarConnected
        )
    }

    @Sendable
    func connect(_ req: Request, ctx: AppRequestContext) async throws -> CalendarConnectStartResponse {
        let tenantID = try ctx.requireTenantID()
        let returnTo = req.uri.queryParameters["returnTo"].map(String.init)
        do {
            let url = try await oauthService.start(tenantID: tenantID, returnTo: returnTo, purpose: .gmail)
            PostHogAnalytics.capture("gmail_connect_started")
            return CalendarConnectStartResponse(authorizeURL: url)
        } catch GoogleCalendarOAuthService.Error.notConfigured {
            throw HTTPError(.serviceUnavailable, message: "Google sign-in is not configured on this server")
        } catch GoogleCalendarOAuthService.Error.invalidReturn {
            throw HTTPError(.badRequest, message: "invalid_return_to")
        }
    }

    @Sendable
    func disconnect(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        try await oauthService.disconnectGmail(tenantID: tenantID)
        return Response(status: .noContent)
    }
}
