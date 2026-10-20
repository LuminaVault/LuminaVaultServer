import Foundation
import Hummingbird
import LuminaVaultShared

extension LearnedDigestResponse: @retroactive ResponseEncodable {}

/// `GET /v1/me/learned?since=<ISO8601>` — what Lumina learned about the user
/// and is waiting for them to keep, edit or forget. Read of own data: mounted
/// with `/v1/me/resurface` (JWT + per-user rate limit, no entitlement gate).
struct MeLearnedController {
    let service: MeLearnedService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/learned", use: learned)
    }

    @Sendable
    func learned(_ request: Request, ctx: AppRequestContext) async throws -> LearnedDigestResponse {
        let user = try ctx.requireIdentity()
        let now = Date()
        let since = try Self.parseSince(request.uri.queryParameters["since"].map(String.init), now: now)
        return try await service.build(tenantID: user.requireID(), since: since, now: now)
    }

    /// ISO 8601, with or without fractional seconds. Missing → seven days
    /// ago. In the future or more than 90 days back → 400.
    static func parseSince(_ raw: String?, now: Date) throws -> Date {
        guard let raw, !raw.isEmpty else { return now.addingTimeInterval(-MeLearnedService.defaultWindow) }
        guard let since = parseISO8601(raw) else {
            throw HTTPError(.badRequest, message: "since must be an ISO 8601 date-time")
        }
        guard since <= now else {
            throw HTTPError(.badRequest, message: "since must not be in the future")
        }
        guard since >= now.addingTimeInterval(-MeLearnedService.maxWindow) else {
            throw HTTPError(.badRequest, message: "since must be within the last 90 days")
        }
        return since
    }

    static func parseISO8601(_ input: String) -> Date? {
        // An unencoded `+01:00` offset arrives form-decoded as a space.
        let raw = input.replacingOccurrences(of: " ", with: "+")
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: raw) ?? fractional.date(from: raw)
    }
}
