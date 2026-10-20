import Foundation
import Hummingbird
import LuminaVaultShared

extension MeBriefResponse: @retroactive ResponseEncodable {}

/// `GET /v1/me/brief?date=yyyy-MM-dd` (default: today on the user's clock)
/// and `POST /v1/me/brief/{briefId}/cards/{cardId}/feedback { action }` → 204.
/// A day with no brief is `{"brief": null}`, not a 404. Mounted with
/// `/v1/me/today` (JWT + per-user rate limit, no entitlement gate).
struct MeBriefController {
    let service: MeBriefService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/brief", use: brief)
        router.post("/brief/:briefId/cards/:cardId/feedback", use: feedback)
    }

    @Sendable
    func brief(_ request: Request, ctx: AppRequestContext) async throws -> MeBriefResponse {
        let user = try ctx.requireIdentity()
        let date = try Self.parseDate(
            request.uri.queryParameters["date"].map(String.init),
            timezone: user.timezone,
            now: Date()
        )
        return try await MeBriefResponse(brief: service.brief(tenantID: user.requireID(), date: date))
    }

    @Sendable
    func feedback(_ request: Request, ctx: AppRequestContext) async throws -> Response {
        let user = try ctx.requireIdentity()
        guard let raw = ctx.parameters.get("briefId"), let briefID = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid brief id")
        }
        guard let cardID = ctx.parameters.get("cardId"), !cardID.isEmpty, cardID.count <= 64 else {
            throw HTTPError(.badRequest, message: "invalid card id")
        }
        let body = try await request.decode(as: BriefCardFeedbackRequest.self, context: ctx)
        let tenantID = try user.requireID()
        try await service.feedback(
            tenantID: tenantID,
            briefID: briefID,
            cardID: cardID,
            action: body.action,
            actorUserID: tenantID
        )
        return Response(status: .noContent)
    }

    /// `yyyy-MM-dd`, a real calendar day. Missing → today in `timezone`.
    static func parseDate(_ raw: String?, timezone: String, now: Date) throws -> String {
        guard let raw, !raw.isEmpty else {
            return ProactivePushBudget.localDay(now, timezone: timezone)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard raw.count == 10, let parsed = formatter.date(from: raw), formatter.string(from: parsed) == raw else {
            throw HTTPError(.badRequest, message: "date must be yyyy-MM-dd")
        }
        return raw
    }
}
