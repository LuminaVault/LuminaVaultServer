import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension SkillListResponse: @retroactive ResponseEncodable {}
extension SkillRunResponse: @retroactive ResponseEncodable {}
extension SkillRunsResponse: @retroactive ResponseEncodable {}
extension LuminaVaultShared.SkillDTO: @retroactive ResponseEncodable {}

/// HTTP surface for the skills runtime.
///
/// HER-148/169 — `POST /v1/skills/:name/run` executes enabled catalog
/// skills; `POST /v1/skills/slash` maps chat commands to skills.
/// HER-247 — adds list / patch / runs endpoints that back the
/// iOS Skills hub UI (Settings → Skills).
struct SkillsController {
    let runner: SkillRunner
    let catalog: SkillCatalog
    let memoryCompileController: MemoryCompileController
    let fluent: HummingbirdFluent.Fluent
    let enforcementEnabled: Bool
    let logger: Logger

    private static let runsMaxLimit = 100
    private static let runsDefaultLimit = 50
    private static let sparklineDays = 14

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.post("/slash", use: runSlashCommand)
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
            uniqueKeysWithValues: states.map { ("\($0.source):\($0.name)", $0) }
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
                userTier: userTier
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
            name: manifest.name
        )
        if let enabled = body.enabled {
            state.enabled = enabled
        }
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
            userTier: userTier
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
            let markdown: String?
            let blocks: String?
        }
        let runs = try await sql.raw("""
        SELECT id, started_at, ended_at, status, error, model_used, mtok_in, mtok_out, markdown, blocks::text AS blocks
        FROM skill_run_log
        WHERE tenant_id = \(bind: tenantID) AND name = \(bind: String(name))
        ORDER BY started_at DESC
        LIMIT \(bind: limit)
        """).all(decoding: RunRow.self)

        let runDTOs = runs.map { row in
            let blocks: [LuminaBlock]? = row.blocks
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([LuminaBlock].self, from: $0) }
            return SkillRunDTO(
                id: row.id,
                startedAt: row.started_at,
                endedAt: row.ended_at,
                status: SkillRunStatus(rawValue: row.status) ?? .error,
                error: row.error,
                modelUsed: row.model_used,
                mtokIn: row.mtok_in,
                mtokOut: row.mtok_out,
                markdown: row.markdown,
                blocks: blocks
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
            uniqueKeysWithValues: buckets.map { ($0.day, $0.count) }
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

    // MARK: - POST /v1/skills/slash

    @Sendable
    func runSlashCommand(_ req: Request, ctx: AppRequestContext) async throws -> SkillRunResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: SkillSlashCommandRequest.self, context: ctx)
        guard let invocation = SlashCommandParser.parse(body.command) else {
            throw HTTPError(.badRequest, message: "slash command must start with /")
        }

        switch invocation.kind {
        case .kbCompile:
            let startedAt = Date()
            let response = try await memoryCompileController.compile(user: user, body: KBCompileRequest())
            let endedAt = Date()
            return SkillRunResponse(
                id: UUID(),
                skillName: "kb-compile",
                status: .success,
                markdown: Self.kbCompileMarkdown(response),
                startedAt: startedAt,
                endedAt: endedAt
            )
        case let .help(markdown):
            let now = Date()
            return SkillRunResponse(
                id: UUID(),
                skillName: "slash-help",
                status: .success,
                markdown: markdown,
                startedAt: now,
                endedAt: now
            )
        case let .skill(name):
            return try await runSkill(
                name: name,
                user: user,
                input: invocation.input,
                arguments: invocation.arguments
            )
        }
    }

    // MARK: - POST /v1/skills/:name/run

    @Sendable
    func runSkill(_ req: Request, ctx: AppRequestContext) async throws -> SkillRunResponse {
        let user = try ctx.requireIdentity()
        guard let name = ctx.parameters.get("name") else {
            throw HTTPError(.badRequest, message: "skill name required")
        }
        let body = await (try? req.decode(as: SkillRunRequest.self, context: ctx)) ?? SkillRunRequest()
        return try await runSkill(
            name: String(name),
            user: user,
            input: body.input,
            arguments: body.arguments ?? [:]
        )
    }

    private func runSkill(
        name: String,
        user: User,
        input: String?,
        arguments: [String: String]
    ) async throws -> SkillRunResponse {
        let tenantID = try user.requireID()
        guard let manifest = try await catalog.manifest(named: name, for: tenantID) else {
            throw HTTPError(.notFound, message: "no skill named \(name)")
        }
        if enforcementEnabled {
            let capability: Capability = manifest.source == .vault ? .skillVaultRun : .skillBuiltinRun
            guard user.entitled(for: capability) else {
                throw EntitlementDeniedError(capability: capability)
            }
        }
        let result = try await runner.run(
            skill: manifest,
            tenantID: tenantID,
            tier: user.tier.isEmpty ? "trial" : user.tier,
            profileUsername: user.username,
            trigger: .manual,
            input: input,
            arguments: arguments
        )
        return Self.response(from: result, skillName: manifest.name)
    }

    static func capExceededHTTPError(_ error: SkillRunCapExceededError) -> HTTPError {
        HTTPError(
            .tooManyRequests,
            headers: [.retryAfter: String(Int(error.retryAfter.rounded(.up)))],
            message: "daily run cap exceeded for this skill"
        )
    }

    // MARK: - Helpers

    private static func buildDTO(
        manifest: SkillManifest,
        state: SkillsState?,
        dailyRunCount: Int,
        userTier: String
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
            bodyExcerpt: String(manifest.body.prefix(200))
        )
    }

    private static func response(from result: SkillRunResult, skillName: String) -> SkillRunResponse {
        SkillRunResponse(
            id: result.runID,
            skillName: skillName,
            status: result.status == "ok" ? .success : .error,
            markdown: result.markdown,
            modelUsed: result.modelUsed,
            mtokIn: result.mtokIn,
            mtokOut: result.mtokOut,
            startedAt: result.startedAt,
            endedAt: result.endedAt
        )
    }

    private static func kbCompileMarkdown(_ response: KBCompileResponse) -> String {
        if response.memoriesIngested == 0 {
            return "KB compile finished. No pending vault files needed ingestion."
        }
        let updated = response.memoriesUpdated.map { "\n- Memories updated: \($0)" } ?? ""
        let duration = response.durationMs.map { "\n- Duration: \($0) ms" } ?? ""
        return "KB compile finished.\n\n- Memories ingested: \(response.memoriesIngested)\(updated)\(duration)"
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
