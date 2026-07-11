import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension UsageSummaryResponse: @retroactive ResponseEncodable {}
extension AnalyticsOverviewResponse: @retroactive ResponseEncodable {}
extension ModelEffectivenessResponse: @retroactive ResponseEncodable {}
extension TeamAnalyticsResponse: @retroactive ResponseEncodable {}
extension AnalyticsMutationResponse: @retroactive ResponseEncodable {}

/// Vault-aware first-party usage intelligence. All queries operate on
/// content-free metadata and enforce VaultAccessService before aggregation.
struct AnalyticsController {
    let fluent: Fluent
    let logger: Logger
    let vaultAccess: VaultAccessService

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/usage-summary", use: usageSummary)
        router.get("/overview", use: overview)
        router.get("/models", use: models)
        router.get("/team", use: team)
        router.post("/events", use: recordEvent)
        router.patch("/recommendations", use: updateRecommendation)
    }

    @Sendable
    func usageSummary(_: Request, ctx: AppRequestContext) async throws -> UsageSummaryResponse {
        let userID = try ctx.requireTenantID()
        let now = Date()
        let start = Self.periodStart(range: .month, now: now)
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let tin: Int64
            let tout: Int64
            let sessions: Int64
            let cost: Int64
        }
        let row = try await sql.raw("""
        SELECT COALESCE((SELECT SUM(mtok_in) FROM usage_meter
                         WHERE tenant_id = \(bind: userID) AND day >= \(bind: start)), 0) AS tin,
               COALESCE((SELECT SUM(mtok_out) FROM usage_meter
                         WHERE tenant_id = \(bind: userID) AND day >= \(bind: start)), 0) AS tout,
               COALESCE((SELECT COUNT(*) FROM conversations
                         WHERE tenant_id = \(bind: userID) AND created_at >= \(bind: start)), 0) AS sessions,
               COALESCE((SELECT SUM(estimated_cost_usd_micros) FROM router_executions
                         WHERE actor_user_id = \(bind: userID) AND occurred_at >= \(bind: start)), 0) AS cost
        """).first(decoding: Row.self)
        let embedding = try await EmbeddingUsage.query(on: fluent.db())
            .filter(\.$tenantID == userID).filter(\.$yearMonth == EmbeddingUsage.yearMonth()).first()
        return UsageSummaryResponse(
            llmTokensIn: Int(row?.tin ?? 0), llmTokensOut: Int(row?.tout ?? 0),
            embeddingTokens: Int(embedding?.tokensUsed ?? 0), sessionsCount: Int(row?.sessions ?? 0),
            estimatedCostCents: Int((row?.cost ?? 0) / 10000), periodStart: start, periodEnd: now
        )
    }

    @Sendable
    func overview(_ req: Request, ctx: AppRequestContext) async throws -> AnalyticsOverviewResponse {
        let range = Self.range(req)
        let scope = Self.scope(req)
        let access = try await resolve(scope: scope, request: req, context: ctx, permission: .read)
        let userID = try ctx.requireTenantID()
        let now = Date()
        let start = Self.periodStart(range: range, now: now)
        let summary = try await summary(vaultID: access.vaultID, userID: userID,
                                        personal: access.isPersonal, since: start)
        async let daily = daily(vaultID: access.vaultID, userID: userID,
                                personal: access.isPersonal, since: start, days: range.days)
        async let health = memoryHealth(vaultID: access.vaultID, now: now)
        let resolvedHealth = try await health
        let recs = try await recommendations(vaultID: access.vaultID, userID: userID,
                                             health: resolvedHealth, since: start, now: now)
        return try await AnalyticsOverviewResponse(
            scope: scope, vaultId: access.vaultID, range: range, periodStart: start, periodEnd: now,
            summary: summary, daily: daily, memoryHealth: resolvedHealth,
            recommendations: recs
        )
    }

    @Sendable
    func models(_ req: Request, ctx: AppRequestContext) async throws -> ModelEffectivenessResponse {
        let range = Self.range(req)
        let scope = Self.scope(req)
        let access = try await resolve(scope: scope, request: req, context: ctx, permission: .read)
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let provider: String
            let model: String
            let requests: Int64
            let successes: Int64
            let fallbacks: Int64
            let latency: Int64
            let p95: Int64
            let tokens: Int64
            let cost: Int64
        }
        let rows = try await sql.raw("""
        SELECT COALESCE(selected_provider, 'unknown') AS provider,
               COALESCE(selected_model, 'unknown') AS model,
               COUNT(*) AS requests,
               COUNT(*) FILTER (WHERE status = 'ok') AS successes,
               COUNT(*) FILTER (WHERE fallback_count > 0) AS fallbacks,
               COALESCE(AVG(latency_ms), 0)::bigint AS latency,
               COALESCE(percentile_disc(0.95) WITHIN GROUP (ORDER BY latency_ms), 0)::bigint AS p95,
               COALESCE(SUM(tokens_in + tokens_out), 0) AS tokens,
               COALESCE(SUM(estimated_cost_usd_micros), 0) AS cost
        FROM router_executions
        WHERE vault_id = \(bind: access.vaultID)
          AND occurred_at >= \(bind: Self.periodStart(range: range, now: Date()))
        GROUP BY selected_provider, selected_model
        ORDER BY requests DESC
        """).all(decoding: Row.self)
        return ModelEffectivenessResponse(range: range, models: rows.map { row in
            let denominator = max(1, Double(row.requests))
            return ModelEffectivenessDTO(
                provider: row.provider, model: row.model, requests: Int(row.requests),
                successRate: Double(row.successes) / denominator,
                fallbackRate: Double(row.fallbacks) / denominator,
                averageLatencyMs: Int(row.latency), p95LatencyMs: Int(row.p95),
                tokens: Int(row.tokens), estimatedCostUsdMicros: row.cost
            )
        })
    }

    @Sendable
    func team(_ req: Request, ctx: AppRequestContext) async throws -> TeamAnalyticsResponse {
        let range = Self.range(req)
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read)
        guard !access.isPersonal, let teamID = access.teamID else {
            throw HTTPError(.unprocessableContent, message: "team analytics requires a shared vault")
        }
        let userID = try ctx.requireTenantID()
        let start = Self.periodStart(range: range, now: Date())
        let aggregate = try await summary(vaultID: access.vaultID, userID: userID,
                                          personal: false, since: start)
        var memberRows: [TeamMemberAnalyticsDTO]?
        if access.canAdmin {
            guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
            struct Row: Decodable {
                let id: UUID
                let name: String
                let captures: Int64
                let retrievals: Int64
                let requests: Int64
                let tokens: Int64
                let cost: Int64
            }
            let rows = try await sql.raw("""
            SELECT u.id, u.username AS name,
                   COALESCE(m.captures, 0) AS captures,
                   COALESCE(q.retrievals, 0) AS retrievals,
                   COALESCE(r.requests, 0) AS requests,
                   COALESCE(r.tokens, 0) AS tokens,
                   COALESCE(r.cost, 0) AS cost
            FROM vault_memberships vm
            JOIN users u ON u.id = vm.user_id
            LEFT JOIN (
                SELECT created_by_user_id AS actor, COUNT(*) AS captures
                FROM memories WHERE tenant_id = \(bind: access.vaultID) AND created_at >= \(bind: start)
                GROUP BY created_by_user_id
            ) m ON m.actor = u.id
            LEFT JOIN (
                SELECT actor_user_id AS actor, COUNT(*) AS retrievals
                FROM analytics_events WHERE vault_id = \(bind: access.vaultID)
                  AND event_name = 'memory_retrieved' AND occurred_at >= \(bind: start)
                GROUP BY actor_user_id
            ) q ON q.actor = u.id
            LEFT JOIN (
                SELECT actor_user_id AS actor, COUNT(*) AS requests,
                       COALESCE(SUM(tokens_in + tokens_out), 0) AS tokens,
                       COALESCE(SUM(estimated_cost_usd_micros), 0) AS cost
                FROM router_executions WHERE vault_id = \(bind: access.vaultID)
                  AND occurred_at >= \(bind: start) GROUP BY actor_user_id
            ) r ON r.actor = u.id
            WHERE vm.vault_id = \(bind: access.vaultID)
              AND EXISTS (SELECT 1 FROM team_memberships tm WHERE tm.team_id = \(bind: teamID)
                          AND tm.user_id = u.id)
            ORDER BY captures + requests DESC, name
            """).all(decoding: Row.self)
            memberRows = rows.map { .init(id: $0.id, displayName: $0.name,
                                          captures: Int($0.captures), retrievals: Int($0.retrievals),
                                          aiRequests: Int($0.requests), tokens: Int($0.tokens),
                                          estimatedCostUsdMicros: $0.cost) }
        }
        return TeamAnalyticsResponse(vaultId: access.vaultID, range: range,
                                     summary: aggregate, members: memberRows)
    }

    @Sendable
    func recordEvent(_ req: Request, ctx: AppRequestContext) async throws -> AnalyticsMutationResponse {
        let body = try await req.decode(as: AnalyticsEventRequest.self, context: ctx)
        if let key = body.idempotencyKey,
           key.count > 128 || !key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        {
            throw HTTPError(.badRequest, message: "invalid idempotencyKey")
        }
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read)
        let userID = try ctx.requireTenantID()
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        let dimensions: String
        switch body.name {
        case .dashboardViewed, .rangeChanged:
            dimensions = body.range.map { "{\"range\":\"\($0.rawValue)\"}" } ?? "{}"
        case .recommendationOpened, .recommendationDismissed, .recommendationSnoozed:
            guard let recommendationID = body.recommendationId,
                  Self.validRecommendationID(recommendationID)
            else { throw HTTPError(.badRequest, message: "recommendationId required") }
            dimensions = "{\"recommendation_id\":\"\(recommendationID)\"}"
        }
        try await sql.raw("""
        INSERT INTO analytics_events
            (vault_id, actor_user_id, event_name, source, dimensions, idempotency_key)
        VALUES (\(bind: access.vaultID), \(bind: userID), \(bind: body.name.rawValue),
                \(bind: body.source.rawValue), \(bind: dimensions)::jsonb, \(bind: body.idempotencyKey))
        ON CONFLICT (actor_user_id, idempotency_key) WHERE idempotency_key IS NOT NULL DO NOTHING
        """).run()
        try await sql.raw("""
        INSERT INTO analytics_daily_rollups (day, vault_id, actor_user_id, metric, value)
        VALUES (CURRENT_DATE, \(bind: access.vaultID), \(bind: userID), \(bind: body.name.rawValue), 1)
        ON CONFLICT (day, vault_id, actor_user_id, metric, dimension_key) DO UPDATE SET
            value = analytics_daily_rollups.value + 1, updated_at = NOW()
        """).run()
        // Bounded retention is enforced opportunistically on writes; the
        // indexed deletes are idempotent and avoid a separate deployment knob.
        try await sql.raw("DELETE FROM analytics_events WHERE occurred_at < NOW() - interval '90 days'").run()
        try await sql.raw("DELETE FROM analytics_daily_rollups WHERE day < CURRENT_DATE - interval '13 months'").run()
        return .init()
    }

    @Sendable
    func updateRecommendation(_ req: Request, ctx: AppRequestContext) async throws -> AnalyticsMutationResponse {
        let body = try await req.decode(as: AnalyticsRecommendationStateRequest.self, context: ctx)
        guard Self.validRecommendationID(body.recommendationId) else {
            throw HTTPError(.badRequest, message: "invalid recommendationId")
        }
        let access = try await vaultAccess.resolve(request: req, context: ctx, requiring: .read)
        let userID = try ctx.requireTenantID()
        let now = Date()
        let dismissed: Date? = body.disposition == .dismiss ? now : nil
        let snoozed: Date? = switch body.disposition {
        case .dismiss: nil
        case .snooze7: Calendar(identifier: .gregorian).date(byAdding: .day, value: 7, to: now)
        case .snooze30: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30, to: now)
        }
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        try await sql.raw("""
        INSERT INTO analytics_recommendation_states
            (vault_id, user_id, recommendation_id, dismissed_at, snoozed_until)
        VALUES (\(bind: access.vaultID), \(bind: userID), \(bind: body.recommendationId),
                \(bind: dismissed), \(bind: snoozed))
        ON CONFLICT (vault_id, user_id, recommendation_id) DO UPDATE SET
            dismissed_at = EXCLUDED.dismissed_at,
            snoozed_until = EXCLUDED.snoozed_until,
            updated_at = NOW()
        """).run()
        return .init()
    }

    // MARK: - Aggregation

    private func resolve(scope: AnalyticsScope, request: Request, context: AppRequestContext,
                         permission: VaultPermission) async throws -> ResolvedVaultAccess
    {
        switch scope {
        case .active:
            return try await vaultAccess.resolve(request: request, context: context, requiring: permission)
        case .personal:
            let userID = try context.requireTenantID()
            return try await vaultAccess.resolve(vaultID: userID, context: context, requiring: permission)
        }
    }

    private func summary(vaultID: UUID, userID: UUID, personal: Bool,
                         since: Date) async throws -> AnalyticsSummaryDTO
    {
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let sessions: Int64
            let requests: Int64
            let tin: Int64
            let tout: Int64
            let captures: Int64
            let retrievals: Int64
            let cost: Int64
        }
        let row = try await sql.raw("""
        SELECT COALESCE((SELECT COUNT(*) FROM conversations WHERE tenant_id = \(bind: userID)
                         AND created_at >= \(bind: since)), 0) AS sessions,
               COALESCE((SELECT COUNT(*) FROM router_executions WHERE vault_id = \(bind: vaultID)
                         AND occurred_at >= \(bind: since)), 0) AS requests,
               COALESCE((SELECT SUM(tokens_in) FROM router_executions WHERE vault_id = \(bind: vaultID)
                         AND occurred_at >= \(bind: since)), 0) AS tin,
               COALESCE((SELECT SUM(tokens_out) FROM router_executions WHERE vault_id = \(bind: vaultID)
                         AND occurred_at >= \(bind: since)), 0) AS tout,
               COALESCE((SELECT COUNT(*) FROM memories WHERE tenant_id = \(bind: vaultID)
                         AND created_at >= \(bind: since) AND review_state != 'rejected'), 0) AS captures,
               COALESCE((SELECT COUNT(*) FROM analytics_events WHERE vault_id = \(bind: vaultID)
                         AND event_name = 'memory_retrieved' AND occurred_at >= \(bind: since)), 0) AS retrievals,
               COALESCE((SELECT SUM(estimated_cost_usd_micros) FROM router_executions
                         WHERE vault_id = \(bind: vaultID) AND occurred_at >= \(bind: since)), 0) AS cost
        """).first(decoding: Row.self)
        return .init(sessions: personal ? Int(row?.sessions ?? 0) : 0, aiRequests: Int(row?.requests ?? 0),
                     tokensIn: Int(row?.tin ?? 0), tokensOut: Int(row?.tout ?? 0),
                     captures: Int(row?.captures ?? 0), retrievals: Int(row?.retrievals ?? 0),
                     estimatedCostUsdMicros: row?.cost ?? 0)
    }

    private func daily(vaultID: UUID, userID: UUID, personal: Bool, since: Date,
                       days: Int) async throws -> [AnalyticsDailyPointDTO]
    {
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let day: Date
            let sessions: Int64
            let requests: Int64
            let tokens: Int64
            let captures: Int64
            let retrievals: Int64
            let cost: Int64
        }
        let rows = try await sql.raw("""
        WITH days AS (
            SELECT generate_series(date_trunc('day', \(bind: since)::timestamptz),
                                   date_trunc('day', NOW()), interval '1 day') AS day
        ), memory_day AS (
            SELECT date_trunc('day', created_at) AS day, COUNT(*) AS captures
            FROM memories WHERE tenant_id = \(bind: vaultID) AND created_at >= \(bind: since)
              AND review_state != 'rejected' GROUP BY 1
        ), retrieval_day AS (
            SELECT date_trunc('day', occurred_at) AS day, COUNT(*) AS retrievals
            FROM analytics_events WHERE vault_id = \(bind: vaultID)
              AND event_name = 'memory_retrieved' AND occurred_at >= \(bind: since) GROUP BY 1
        ), router_day AS (
            SELECT date_trunc('day', occurred_at) AS day, COUNT(*) AS requests,
                   COALESCE(SUM(tokens_in + tokens_out), 0) AS tokens,
                   COALESCE(SUM(estimated_cost_usd_micros), 0) AS cost
            FROM router_executions WHERE vault_id = \(bind: vaultID) AND occurred_at >= \(bind: since)
            GROUP BY 1
        ), session_day AS (
            SELECT date_trunc('day', created_at) AS day, COUNT(*) AS sessions
            FROM conversations WHERE tenant_id = \(bind: userID) AND created_at >= \(bind: since)
            GROUP BY 1
        )
        SELECT d.day, COALESCE(s.sessions, 0) AS sessions,
               COALESCE(r.requests, 0) AS requests, COALESCE(r.tokens, 0) AS tokens,
               COALESCE(m.captures, 0) AS captures, COALESCE(q.retrievals, 0) AS retrievals,
               COALESCE(r.cost, 0) AS cost
        FROM days d LEFT JOIN memory_day m ON m.day = d.day
        LEFT JOIN retrieval_day q ON q.day = d.day
        LEFT JOIN router_day r ON r.day = d.day LEFT JOIN session_day s ON s.day = d.day
        ORDER BY d.day LIMIT \(bind: days)
        """).all(decoding: Row.self)
        return rows.map { .init(date: $0.day, sessions: personal ? Int($0.sessions) : 0, aiRequests: Int($0.requests),
                                tokens: Int($0.tokens), captures: Int($0.captures),
                                retrievals: Int($0.retrievals), estimatedCostUsdMicros: $0.cost) }
    }

    private func memoryHealth(vaultID: UUID, now: Date) async throws -> MemoryHealthDTO {
        guard let sql = fluent.db() as? any SQLDatabase else { throw HTTPError(.internalServerError) }
        struct Row: Decodable {
            let total: Int64
            let stale: Int64
            let never_retrieved: Int64
            let unorganized: Int64
            let pending: Int64
            let freshness: Double
            let engagement: Double
            let organization: Double
            let review: Double
        }
        let row = try await sql.raw("""
        SELECT COUNT(*) AS total,
               COUNT(*) FILTER (WHERE COALESCE(last_reviewed_at, last_accessed_at, created_at) < \(bind: now) - interval '30 days') AS stale,
               COUNT(*) FILTER (WHERE query_hit_count = 0) AS never_retrieved,
               COUNT(*) FILTER (WHERE COALESCE(cardinality(tags), 0) = 0 AND space_id IS NULL AND source_vault_file_id IS NULL) AS unorganized,
               COUNT(*) FILTER (WHERE review_state = 'pending') AS pending,
               COALESCE(AVG(exp(-ln(2.0) * GREATEST(0, EXTRACT(EPOCH FROM (\(bind: now) - COALESCE(last_reviewed_at, last_accessed_at, created_at))) / 86400.0) / 30.0)), 0) AS freshness,
               COALESCE(AVG(LEAST(1.0, ln(1.0 + access_count + query_hit_count) / ln(6.0))), 0) AS engagement,
               COALESCE(AVG((CASE WHEN COALESCE(cardinality(tags), 0) > 0 THEN 0.5 ELSE 0 END) +
                            (CASE WHEN space_id IS NOT NULL OR source_vault_file_id IS NOT NULL THEN 0.5 ELSE 0 END)), 0) AS organization,
               COALESCE(AVG(CASE WHEN review_state != 'pending' AND COALESCE(last_reviewed_at, last_accessed_at, created_at) >= \(bind: now) - interval '30 days' THEN 1.0 ELSE 0 END), 0) AS review
        FROM memories WHERE tenant_id = \(bind: vaultID) AND review_state != 'rejected'
        """).first(decoding: Row.self)
        let value = row ?? .init(total: 0, stale: 0, never_retrieved: 0, unorganized: 0,
                                 pending: 0, freshness: 0, engagement: 0, organization: 0, review: 0)
        let freshness = Int((value.freshness * 100).rounded())
        let engagement = Int((value.engagement * 100).rounded())
        let organization = Int((value.organization * 100).rounded())
        let review = Int((value.review * 100).rounded())
        let totalScore = value.total == 0 ? 0 : Self.weightedHealthScore(
            freshness: freshness,
            engagement: engagement,
            organization: organization,
            review: review
        )
        return .init(score: totalScore, totalMemories: Int(value.total), staleCount: Int(value.stale),
                     neverRetrievedCount: Int(value.never_retrieved), unorganizedCount: Int(value.unorganized),
                     pendingReviewCount: Int(value.pending), components: [
                         .init(key: "freshness", title: "Freshness", score: freshness, weight: 35),
                         .init(key: "engagement", title: "Engagement", score: engagement, weight: 25),
                         .init(key: "organization", title: "Organization", score: organization, weight: 20),
                         .init(key: "review", title: "Review readiness", score: review, weight: 20),
                     ])
    }

    private func recommendations(vaultID: UUID, userID: UUID, health: MemoryHealthDTO,
                                 since: Date, now: Date) async throws -> [AnalyticsRecommendationDTO]
    {
        var values: [AnalyticsRecommendationDTO] = []
        if health.staleCount > 0 {
            values.append(.init(id: "memory-review-overdue", title: "Review older memories",
                                detail: "\(health.staleCount) memories have not been revisited in 30 days.",
                                severity: .important, actionTitle: "Open review queue",
                                deepLink: "/memories?filter=review-overdue"))
        }
        if health.pendingReviewCount > 0 {
            values.append(.init(id: "memory-moderation-pending", title: "Resolve pending memories",
                                detail: "\(health.pendingReviewCount) compiled memories are waiting for approval.",
                                severity: .attention, actionTitle: "Review pending",
                                deepLink: "/memories?reviewState=pending"))
        }
        if health.unorganizedCount > 0 {
            values.append(.init(id: "memory-organization", title: "Organize loose memories",
                                detail: "\(health.unorganizedCount) memories have no tags, Space, or source.",
                                severity: .attention, actionTitle: "Organize memories",
                                deepLink: "/memories?filter=unorganized"))
        }
        if health.neverRetrievedCount >= 5 {
            values.append(.init(id: "memory-never-retrieved", title: "Check unused knowledge",
                                detail: "\(health.neverRetrievedCount) memories have never appeared in retrieval.",
                                severity: .info, actionTitle: "Inspect unused",
                                deepLink: "/memories?filter=unused"))
        }
        guard let sql = fluent.db() as? any SQLDatabase else { return Array(values.prefix(5)) }
        struct ModelRow: Decodable { let requests: Int64; let failures: Int64; let latency: Int64 }
        if let model = try await sql.raw("""
            SELECT COUNT(*) AS requests, COUNT(*) FILTER (WHERE status != 'ok') AS failures,
                   COALESCE(AVG(latency_ms), 0)::bigint AS latency
            FROM router_executions WHERE vault_id = \(bind: vaultID) AND occurred_at >= \(bind: since)
        """).first(decoding: ModelRow.self), model.requests >= 10,
            Double(model.failures) / Double(model.requests) >= 0.10 || model.latency >= 10000
        {
            values.append(.init(id: "model-reliability", title: "Review model routing",
                                detail: "Recent AI runs are slower or less reliable than expected.",
                                severity: .attention, actionTitle: "Compare models", deepLink: "/analytics#models"))
        }
        struct StateRow: Decodable { let recommendation_id: String }
        let hidden = try await sql.raw("""
        SELECT recommendation_id FROM analytics_recommendation_states
        WHERE vault_id = \(bind: vaultID) AND user_id = \(bind: userID)
          AND (dismissed_at IS NOT NULL OR snoozed_until > \(bind: now))
        """).all(decoding: StateRow.self)
        let hiddenIDs = Set(hidden.map(\.recommendation_id))
        return Array(values.filter { !hiddenIDs.contains($0.id) }.prefix(5))
    }

    private static func range(_ req: Request) -> AnalyticsRange {
        req.uri.queryParameters["range"].flatMap { AnalyticsRange(rawValue: String($0)) } ?? .month
    }

    private static func scope(_ req: Request) -> AnalyticsScope {
        req.uri.queryParameters["scope"].flatMap { AnalyticsScope(rawValue: String($0)) } ?? .active
    }

    private static func periodStart(range: AnalyticsRange, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
    }

    private static func validRecommendationID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func weightedHealthScore(freshness: Int, engagement: Int,
                                    organization: Int, review: Int) -> Int
    {
        let score = Double(freshness) * 0.35 + Double(engagement) * 0.25
            + Double(organization) * 0.20 + Double(review) * 0.20
        return min(100, max(0, Int(score.rounded())))
    }
}
