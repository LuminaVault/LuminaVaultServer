import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

extension InsightListResponse: ResponseEncodable {}
extension InsightDTO: ResponseEncodable {}

/// HER-37 Slice D — proactive findings surface ("what Lumina noticed").
///
/// Endpoints:
/// - `GET /v1/insights?section=<section>&limit=<n>` — active (non-
///   dismissed) insights for the tenant.
/// - `GET /v1/insights/synthesis/latest` — newest `thisWeek` /
///   `thisMonth` row, regardless of dismissal (it's a snapshot, not a
///   nag).
/// - `POST /v1/insights/{id}/dismiss` — flag a row as dismissed; it
///   stays in the table for audit but stops appearing in `list`.
///
/// HER-244 originally shipped this as a stub returning `[]`. HER-37
/// Slice D wires real Postgres-backed persistence + the SynthesisWorker
/// that produces the rows.
struct InsightsController {
    let fluent: Fluent
    let logger: Logger

    private static let maxLimit = 100
    private static let defaultLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.get("/synthesis/latest", use: latestSynthesis)
        router.post("/:id/dismiss", use: dismiss)
    }

    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> InsightListResponse {
        let tenantID = try ctx.requireTenantID()
        let section = Self.parseSection(req)
        let limit = Self.parseLimit(req)
        var q = Insight.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$dismissedAt == nil)
            .sort(\.$createdAt, .descending)
            .limit(limit)
        if let section { q = q.filter(\.$section == section.rawValue) }
        let rows = try await q.all()
        return try InsightListResponse(insights: rows.map { try $0.toDTO() }, nextCursor: nil)
    }

    /// Returns the most recent synthesis row (weekly preferred, monthly
    /// fallback). 404 if none exists yet — the iOS surface should hide
    /// the synthesis card until at least one ships.
    @Sendable
    func latestSynthesis(_: Request, ctx: AppRequestContext) async throws -> InsightDTO {
        let tenantID = try ctx.requireTenantID()
        let row = try await Insight.query(on: fluent.db(), tenantID: tenantID)
            .group(.or) { group in
                group.filter(\.$section == InsightSection.thisWeek.rawValue)
                group.filter(\.$section == InsightSection.thisMonth.rawValue)
            }
            .sort(\.$createdAt, .descending)
            .first()
        guard let row else { throw HTTPError(.notFound, message: "no synthesis available yet") }
        return try row.toDTO()
    }

    @Sendable
    func dismiss(_: Request, ctx: AppRequestContext) async throws -> Response {
        let tenantID = try ctx.requireTenantID()
        let id = try Self.parseID(ctx)
        guard let row = try await Insight.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$id == id)
            .first()
        else { throw HTTPError(.notFound, message: "insight not found") }
        if row.dismissedAt == nil {
            row.dismissedAt = Date()
            try await row.save(on: fluent.db())
        }
        return Response(status: .noContent)
    }

    // MARK: - Helpers

    private static func parseSection(_ req: Request) -> InsightSection? {
        guard let raw = req.uri.queryParameters["section"] else { return nil }
        return InsightSection(rawValue: String(raw))
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return defaultLimit
        }
        return max(1, min(raw, maxLimit))
    }

    private static func parseID(_ ctx: AppRequestContext) throws -> UUID {
        guard let raw = ctx.parameters.get("id"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "invalid insight id")
        }
        return id
    }
}
