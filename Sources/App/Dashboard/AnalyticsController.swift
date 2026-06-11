import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension UsageSummaryResponse: @retroactive ResponseEncodable {}

/// HER-Insights — per-tenant usage analytics for the current calendar month.
/// Aggregates the raw-SQL `usage_meter` table (LLM tokens, written by
/// `UsageMeterService`) and the `embedding_usage` counter. Powers the Home
/// "Insights" card.
///
/// `GET /v1/analytics/usage-summary` → `UsageSummaryResponse`.
struct AnalyticsController {
    let fluent: Fluent
    let logger: Logger

    /// Coarse blended cost estimate. Real per-model pricing is not wired yet,
    /// so this is a single rate over all tokens — good enough for a "you've
    /// used roughly $X this month" signal, not for billing.
    private static let centsPerMillionTokens = 40

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/usage-summary", use: usageSummary)
    }

    @Sendable
    func usageSummary(_: Request, ctx: AppRequestContext) async throws -> UsageSummaryResponse {
        let tenantID = try ctx.requireTenantID()
        let db = fluent.db()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date()
        let periodStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now

        async let llm = Self.llmTokens(tenantID: tenantID, since: periodStart, db: db)
        async let embedding = Self.embeddingTokens(tenantID: tenantID, db: db)
        async let sessions = Conversation.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$createdAt >= periodStart)
            .count()

        let (tokensIn, tokensOut) = try await llm
        let embeddingTokens = try await embedding
        let sessionsCount = try await sessions

        let totalLLM = tokensIn + tokensOut
        let estimatedCostCents = Int((Double(totalLLM) / 1_000_000.0) * Double(Self.centsPerMillionTokens))

        return UsageSummaryResponse(
            llmTokensIn: tokensIn,
            llmTokensOut: tokensOut,
            embeddingTokens: embeddingTokens,
            sessionsCount: sessionsCount,
            estimatedCostCents: estimatedCostCents,
            periodStart: periodStart,
            periodEnd: now
        )
    }

    // MARK: - Aggregations

    private static func llmTokens(tenantID: UUID, since: Date, db: any Database) async throws -> (Int, Int) {
        guard let sql = db as? any SQLDatabase else { return (0, 0) }
        struct Row: Decodable { let tin: Int; let tout: Int }
        let row = try await sql.raw("""
        SELECT COALESCE(SUM(mtok_in), 0)::int AS tin,
               COALESCE(SUM(mtok_out), 0)::int AS tout
        FROM usage_meter
        WHERE tenant_id = \(bind: tenantID) AND day >= \(bind: since)
        """).first(decoding: Row.self)
        return (row?.tin ?? 0, row?.tout ?? 0)
    }

    private static func embeddingTokens(tenantID: UUID, db: any Database) async throws -> Int {
        let yearMonth = EmbeddingUsage.yearMonth()
        let row = try await EmbeddingUsage.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$yearMonth == yearMonth)
            .first()
        return Int(row?.tokensUsed ?? 0)
    }
}
