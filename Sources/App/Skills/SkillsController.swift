import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension SkillListResponse: ResponseEncodable {}
extension SkillRunsResponse: ResponseEncodable {}
extension LuminaVaultShared.SkillDTO: ResponseEncodable {}

/// HTTP surface for the skills runtime.
///
/// HER-148/169 — `POST /v1/skills/:name/run` remains a 501 stub.
/// HER-247 — adds list / patch / runs endpoints that back the
/// iOS Skills hub UI (Settings → Skills).
struct SkillsController {
    let runner: SkillRunner
    let catalog: SkillCatalog
    let fluent: HummingbirdFluent.Fluent
    let enforcementEnabled: Bool
    let logger: Logger

    private static let runsMaxLimit = 100
    private static let runsDefaultLimit = 50
    private static let sparklineDays = 14

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.patch("/:name", use: patch)
        router.get("/:name/runs", use: runs)
        router.post("/:name/run", use: runSkill)
    }

    // MARK: - GET /v1/skills

    @Sendable
    func list(_: Request, ctx: AppRequestContext) async throws -> SkillListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let manifests = try await catalog.manifests(for: tenantID)
        let states = try await SkillsState.query(on: fluent.db())
            .filter(\.$tenantID == tenantID)
            .all()
        let stateByKey: [String: SkillsState] = Dictionary(
            uniqueKeysWithValues: states.map { ("\($0.source):\($0.name)", $0) },
        )
        let dailyCounts = try await dailyRunCounts(tenantID: tenantID, names: nil)
        let userTier = user.tier.isEmpty ? "trial" : user.tier

        let skills = manifests.map { manifest -> LuminaVaultShared.SkillDTO in
            let key = "\(manifest.source.rawValue):\(manifest.name)"
            let state = stateByKey[key]
            return Self.buildDTO(
                manifest: manifest,
                state: state,
                dailyRunCount: dailyCounts[manifest.name] ?? 0,
                userTier: userTier,
            )
        }
        return SkillListResponse(skills: skills)
    }

    // MARK: - PATCH /v1/skills/:name

    @Sendable
    func patch(_ req: Request, ctx: AppRequestContext) async throws -> LuminaVaultShared.SkillDTO {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        guard let name = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        let body = try await req.decode(as: SkillPatchRequest.self, context: ctx)

        guard let manifest = try await catalog.manifest(named: String(name), for: tenantID) else {
            throw HTTPError(.notFound, message: "no skill named \(name)")
        }

        if let override = body.scheduleOverride, !override.isEmpty {
            guard (try? CronExpression(override)) != nil else {
                throw HTTPError(.badRequest, message: "invalid cron expression")
            }
        }

        let db = fluent.db()
        let existing = try await SkillsState.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$source == manifest.source.rawValue)
            .filter(\.$name == manifest.name)
            .first()

        let state = existing ?? SkillsState(
            tenantID: tenantID,
            source: manifest.source.rawValue,
            name: manifest.name,
        )
        if let enabled = body.enabled { state.enabled = enabled }
        if let override = body.scheduleOverride {
            state.scheduleOverride = override.isEmpty ? nil : override
        }
        if let category = body.apnsCategory {
            state.apnsCategory = category.rawValue
        }
        try await state.save(on: db)

        let counts = try await dailyRunCounts(tenantID: tenantID, names: [manifest.name])
        let userTier = user.tier.isEmpty ? "trial" : user.tier
        return Self.buildDTO(
            manifest: manifest,
            state: state,
            dailyRunCount: counts[manifest.name] ?? 0,
            userTier: userTier,
        )
    }

    // MARK: - GET /v1/skills/:name/runs

    @Sendable
    func runs(_ req: Request, ctx: AppRequestContext) async throws -> SkillRunsResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        guard let name = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        let limit = Self.parseLimit(req)

        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "sql unavailable")
        }

        struct RunRow: Decodable {
            let id: UUID
            let started_at: Date
            let ended_at: Date?
            let status: String
            let error: String?
            let model_used: String?
            let mtok_in: Int
            let mtok_out: Int
        }
        let runs = try await sql.raw("""
        SELECT id, started_at, ended_at, status, error, model_used, mtok_in, mtok_out
        FROM skill_run_log
        WHERE tenant_id = \(bind: tenantID) AND name = \(bind: String(name))
        ORDER BY started_at DESC
        LIMIT \(bind: limit)
        """).all(decoding: RunRow.self)

        let runDTOs = runs.map { row in
            SkillRunDTO(
                id: row.id,
                startedAt: row.started_at,
                endedAt: row.ended_at,
                status: SkillRunStatus(rawValue: row.status) ?? .error,
                error: row.error,
                modelUsed: row.model_used,
                mtokIn: row.mtok_in,
                mtokOut: row.mtok_out,
            )
        }

        struct BucketRow: Decodable { let day: Date; let count: Int }
        let buckets = try await sql.raw("""
        SELECT date_trunc('day', started_at) AS day, COUNT(*)::int AS count
        FROM skill_run_log
        WHERE tenant_id = \(bind: tenantID)
          AND name = \(bind: String(name))
          AND started_at >= NOW() - INTERVAL '14 days'
        GROUP BY day
        """).all(decoding: BucketRow.self)
        let bucketByDay: [Date: Int] = Dictionary(
            uniqueKeysWithValues: buckets.map { ($0.day, $0.count) },
        )
        var sparkline: [SkillSparklinePoint] = []
        sparkline.reserveCapacity(Self.sparklineDays)
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        for offset in stride(from: Self.sparklineDays - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -offset, to: today) ?? today
            sparkline.append(SkillSparklinePoint(day: day, count: bucketByDay[day] ?? 0))
        }

        return SkillRunsResponse(runs: runDTOs, sparkline: sparkline, nextCursor: nil)
    }

    // MARK: - POST /v1/skills/:name/run (HER-148 / HER-169 stub kept)

    @Sendable
    func runSkill(_: Request, ctx: AppRequestContext) async throws -> HTTPResponse.Status {
        let user = try ctx.requireIdentity()
        guard let name = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        if enforcementEnabled {
            let manifest = try await catalog.manifest(named: String(name), for: user.requireID())
            let capability: Capability = manifest?.source == .vault ? .skillVaultRun : .skillBuiltinRun
            guard user.entitled(for: capability) else {
                throw EntitlementDeniedError(capability: capability)
            }
        }
        throw HTTPError(.notImplemented, message: "HER-148 scaffold — SkillRunner lands in HER-169")
    }

    static func capExceededHTTPError(_ error: SkillRunCapExceededError) -> HTTPError {
        HTTPError(
            .tooManyRequests,
            headers: [.retryAfter: String(Int(error.retryAfter.rounded(.up)))],
            message: "daily run cap exceeded for this skill",
        )
    }

    // MARK: - Helpers

    private static func buildDTO(
        manifest: SkillManifest,
        state: SkillsState?,
        dailyRunCount: Int,
        userTier: String,
    ) -> LuminaVaultShared.SkillDTO {
        LuminaVaultShared.SkillDTO(
            id: "\(manifest.source.rawValue):\(manifest.name)",
            source: LuminaVaultShared.SkillSource(rawValue: manifest.source.rawValue) ?? .builtin,
            name: manifest.name,
            title: manifest.name,
            descriptionText: manifest.description,
            capability: LuminaVaultShared.SkillCapability(rawValue: manifest.capability.rawValue) ?? .medium,
            schedule: manifest.schedule,
            scheduleOverride: state?.scheduleOverride,
            enabled: state?.enabled ?? true,
            lastRunAt: state?.lastRunAt,
            lastStatus: state?.lastStatus.flatMap { LuminaVaultShared.SkillRunStatus(rawValue: $0) },
            lastError: state?.lastError,
            dailyRunCount: dailyRunCount,
            dailyRunCap: manifest.dailyRunCap?.value(for: userTier) ?? 0,
            apnsCategory: state?.apnsCategory.flatMap { LuminaVaultShared.APNSCategory(rawValue: $0) },
            bodyExcerpt: String(manifest.body.prefix(200)),
        )
    }

    private static func parseLimit(_ req: Request) -> Int {
        guard let raw = req.uri.queryParameters["limit"].flatMap({ Int(String($0)) }) else {
            return runsDefaultLimit
        }
        return max(1, min(raw, runsMaxLimit))
    }

    private func dailyRunCounts(tenantID: UUID, names: [String]?) async throws -> [String: Int] {
        guard let sql = fluent.db() as? any SQLDatabase else { return [:] }
        struct Row: Decodable { let name: String; let count: Int }
        let rows: [Row] = if let names, !names.isEmpty {
            try await sql.raw("""
            SELECT name, COUNT(*)::int AS count
            FROM skill_run_log
            WHERE tenant_id = \(bind: tenantID)
              AND started_at >= date_trunc('day', NOW())
              AND name = ANY(\(bind: names))
            GROUP BY name
            """).all(decoding: Row.self)
        } else {
            try await sql.raw("""
            SELECT name, COUNT(*)::int AS count
            FROM skill_run_log
            WHERE tenant_id = \(bind: tenantID)
              AND started_at >= date_trunc('day', NOW())
            GROUP BY name
            """).all(decoding: Row.self)
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.count) })
    }
}

struct EntitlementDeniedError: HTTPResponseError {
    let capability: Capability

    var status: HTTPResponse.Status {
        .init(code: 402, reasonPhrase: "Payment Required")
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        try EntitlementMiddleware.paywallResponse(for: capability)
    }
}
