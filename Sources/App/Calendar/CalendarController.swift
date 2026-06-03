import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension CalendarStatusResponse: @retroactive ResponseEncodable {}
extension CalendarConnectStartResponse: @retroactive ResponseEncodable {}
extension CalendarEventsResponse: @retroactive ResponseEncodable {}
extension CalendarEventDTO: @retroactive ResponseEncodable {}

/// HER-340 — Google Calendar connect/status/disconnect + cached-events read.
///
/// Authed endpoints (tenant-scoped via `jwtAuthenticator`):
/// - `GET    /v1/calendar/status`     — connection state for the pane.
/// - `POST   /v1/calendar/connect`    — returns the Google consent URL.
/// - `POST   /v1/calendar/disconnect` — revoke + purge.
/// - `GET    /v1/calendar/events`     — upcoming cached events.
///
/// Public endpoint (no JWT — Google redirects the user's browser here):
/// - `GET /v1/calendar/oauth/callback` — exchange code, 302 back to the app
///   via the `luminavault://` scheme so ASWebAuthenticationSession dismisses.
///
/// Sync + token refresh live in `CalendarSyncWorker` / `CalendarTokenStore`.
struct CalendarController {
    let fluent: Fluent
    let oauthService: GoogleCalendarOAuthService
    let syncService: CalendarSyncService
    let logger: Logger

    private static let maxEvents = 50

    /// Tenant-scoped routes; mount on a `jwtAuthenticator` group.
    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("status", use: status)
        router.post("connect", use: connect)
        router.post("disconnect", use: disconnect)
        router.get("events", use: events)
        router.post("events", use: createEvent)
    }

    /// Public OAuth callback; mount on the unauthenticated base router.
    func addPublicRoutes(to router: Router<AppRequestContext>) {
        router.get("/v1/calendar/oauth/callback", use: oauthCallback)
    }

    @Sendable
    func status(_: Request, ctx: AppRequestContext) async throws -> CalendarStatusResponse {
        let tenantID = try ctx.requireTenantID()
        let s = try await oauthService.status(tenantID: tenantID)
        return CalendarStatusResponse(
            connected: s.connected,
            needsReauth: s.needsReauth,
            accountEmail: s.accountEmail,
            lastSyncedAt: s.lastSyncedAt,
        )
    }

    @Sendable
    func connect(_: Request, ctx: AppRequestContext) async throws -> CalendarConnectStartResponse {
        let tenantID = try ctx.requireTenantID()
        do {
            let url = try await oauthService.start(tenantID: tenantID)
            return CalendarConnectStartResponse(authorizeURL: url)
        } catch GoogleCalendarOAuthService.Error.notConfigured {
            throw HTTPError(.serviceUnavailable, message: "Google Calendar is not configured on this server")
        }
    }

    @Sendable
    func disconnect(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        try await oauthService.disconnect(tenantID: tenantID)
        return Response(status: .noContent)
    }

    @Sendable
    func events(_ req: Request, ctx: AppRequestContext) async throws -> CalendarEventsResponse {
        let tenantID = try ctx.requireTenantID()
        let limit = Self.parseLimit(req)
        let now = Date()
        let rows = try await CalendarEvent.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$status != "cancelled")
            .filter(\.$endsAt >= now)
            .sort(\.$startsAt, .ascending)
            .limit(limit)
            .all()
        return CalendarEventsResponse(events: rows.map(Self.toDTO))
    }

    @Sendable
    func createEvent(_ req: Request, ctx: AppRequestContext) async throws -> CalendarEventDTO {
        let tenantID = try ctx.requireTenantID()
        let body = try await req.decode(as: CalendarCreateEventRequest.self, context: ctx)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw HTTPError(.badRequest, message: "event title required")
        }
        guard body.endsAt > body.startsAt else {
            throw HTTPError(.badRequest, message: "event end must be after start")
        }
        do {
            let saved = try await syncService.createEvent(
                tenantID: tenantID,
                title: title,
                startsAt: body.startsAt,
                endsAt: body.endsAt,
                location: body.location,
                notes: body.notes,
                attendees: body.attendees ?? [],
            )
            return Self.toDTO(saved)
        } catch CalendarTokenStore.Error.notConnected, CalendarTokenStore.Error.needsReauth {
            throw HTTPError(.conflict, message: "Google Calendar is not connected")
        }
    }

    /// Unauthenticated — Google redirects here with `code` + `state` (or
    /// `error`). Hands control back to the app via a `luminavault://` 302.
    @Sendable
    func oauthCallback(_ req: Request, ctx _: AppRequestContext) async throws -> Response {
        let params = req.uri.queryParameters
        let state = params["state"].map(String.init) ?? ""
        let code = params["code"].map(String.init)
        let error = params["error"].map(String.init)
        let redirect = await oauthService.handleCallback(state: state, code: code, error: error)
        var headers = HTTPFields()
        headers[.location] = redirect
        return Response(status: .seeOther, headers: headers)
    }

    // MARK: - Helpers

    private static func toDTO(_ e: CalendarEvent) -> CalendarEventDTO {
        CalendarEventDTO(
            id: (try? e.requireID().uuidString) ?? "",
            source: e.source,
            externalID: e.externalID,
            title: e.title,
            notes: e.notes,
            location: e.location,
            startsAt: e.startsAt,
            endsAt: e.endsAt,
            allDay: e.allDay,
            status: e.status,
            organizer: e.organizer,
            htmlLink: e.htmlLink,
        )
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return maxEvents
        }
        return max(1, min(raw, maxEvents))
    }
}
