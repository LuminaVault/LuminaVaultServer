import Foundation
import Hummingbird
import LuminaVaultShared

extension MeetingBriefResponse: @retroactive ResponseEncodable {}

/// `GET /v1/calendar/events/{id}/brief` — the notes that bear on one of the
/// caller's calendar events, for the sheet the pre-meeting push opens
/// (`luminavault://meeting/<eventId>`). Works whether or not a push was sent:
/// with one, it shows what the push counted; without, it matches now (one
/// embedding call). Another tenant's event, or no such event, is a 404.
struct MeetingBriefController {
    let service: MeetingBriefService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/events/:id/brief", use: brief)
    }

    @Sendable
    func brief(_: Request, ctx: AppRequestContext) async throws -> MeetingBriefResponse {
        let tenantID = try ctx.requireTenantID()
        guard let raw = ctx.parameters.get("id"), let eventID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid event id")
        }
        guard let response = try await service.brief(tenantID: tenantID, eventID: eventID) else {
            throw HTTPError(.notFound, message: "event not found")
        }
        return response
    }
}
