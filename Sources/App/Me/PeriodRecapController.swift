import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared

extension PeriodRecapResponse: @retroactive ResponseEncodable {}

/// `GET /v1/me/recap/period?period=year|month&year=YYYY[&month=1-12]` — the
/// year or month in review. Mounted beside `/v1/me/recap`: JWT + per-user
/// rate limit, read of own data, no entitlement gate.
///
/// `year` defaults to the current year and `month` to the current month, both
/// in the user's timezone. `month` is refused for a year recap.
struct PeriodRecapController {
    let service: PeriodRecapService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/recap/period", use: recap)
    }

    @Sendable
    func recap(_ request: Request, ctx: AppRequestContext) async throws -> EditedResponse<PeriodRecapResponse> {
        let user = try ctx.requireIdentity()
        let query = request.uri.queryParameters
        let params = try Self.parse(
            period: query["period"].map(String.init),
            year: query["year"].map(String.init),
            month: query["month"].map(String.init),
            timezone: user.timezone,
            now: Date()
        )
        let recap = try await service.build(user: user, kind: params.kind, year: params.year, month: params.month)
        var headers = HTTPFields()
        headers[.cacheControl] = Self.cacheControl(for: recap)
        return EditedResponse(headers: headers, response: recap)
    }

    struct Params: Equatable {
        let kind: RecapPeriodKind
        let year: Int
        let month: Int?
    }

    static func parse(period: String?, year: String?, month: String?, timezone: String, now: Date) throws -> Params {
        let kind: RecapPeriodKind
        switch period {
        case nil, "":
            kind = .year
        case let raw?:
            guard let parsed = RecapPeriodKind(rawValue: raw) else {
                throw HTTPError(.badRequest, message: "period must be year or month")
            }
            kind = parsed
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .gmt
        let today = calendar.dateComponents([.year, .month], from: now)

        let parsedYear: Int
        if let year, !year.isEmpty {
            guard let value = Int(year), (2000 ... 9999).contains(value) else {
                throw HTTPError(.badRequest, message: "year must be a four-digit year")
            }
            parsedYear = value
        } else {
            parsedYear = today.year ?? 2026
        }

        switch kind {
        case .year:
            guard month?.isEmpty ?? true else {
                throw HTTPError(.badRequest, message: "month is only for period=month")
            }
            return Params(kind: .year, year: parsedYear, month: nil)
        case .month:
            if let month, !month.isEmpty {
                guard let value = Int(month), (1 ... 12).contains(value) else {
                    throw HTTPError(.badRequest, message: "month must be 1-12")
                }
                return Params(kind: .month, year: parsedYear, month: value)
            }
            return Params(kind: .month, year: parsedYear, month: today.month ?? 1)
        }
    }

    /// A pending themes card must not be cached, or the client's follow-up
    /// fetch would get the same pending card back.
    static func cacheControl(for recap: PeriodRecapResponse) -> String {
        if recap.themes?.status == .pending {
            return "private, no-cache"
        }
        return recap.isComplete ? "private, max-age=3600" : "private, max-age=300"
    }
}
