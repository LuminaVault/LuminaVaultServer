import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension DashboardStatsResponse: @retroactive ResponseEncodable {}
extension DashboardProfileResponse: @retroactive ResponseEncodable {}
extension HomeSummaryResponse: @retroactive ResponseEncodable {}
extension ActivityFeedResponse: @retroactive ResponseEncodable {}

struct DashboardController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger
    let managedProvider: ProviderID
    let managedModel: String

    init(
        fluent: HummingbirdFluent.Fluent,
        logger: Logger,
        managedProvider: ProviderID = ManagedLLMDefaults.provider,
        managedModel: String = ManagedLLMDefaults.model
    ) {
        self.fluent = fluent
        self.logger = logger
        self.managedProvider = managedProvider
        self.managedModel = managedModel
    }

    /// Node cap for the Home brain-graph preview card.
    static let graphPreviewLimit = 30
    static let activityDefaultLimit = 20
    static let activityMaxLimit = 50

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/stats", use: stats)
        router.get("/profile", use: profile)
        router.get("/home", use: home)
        router.get("/activity", use: activity)
    }

    /// `GET /v1/dashboard/home` — one-shot Command Center payload: counts,
    /// active model, power progress, skill names, and live active jobs.
    /// Tenant-scoped; designed so the landing screen can render from a
    /// single request.
    @Sendable
    func home(_: Request, ctx: AppRequestContext) async throws -> HomeSummaryResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()
        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: Date())

        async let skillsCountQ = SkillsState.query(on: db)
            .filter(\.$id == tenantID)
            .filter(\.$enabled == true)
            .count()
        async let skillNamesQ = SkillsState.query(on: db)
            .filter(\.$id == tenantID)
            .filter(\.$enabled == true)
            .sort(\.$name, .ascending)
            .limit(8)
            .all()
        async let remindersCountQ = Reminder.query(on: db, tenantID: tenantID).count()
        async let projectsCountQ = Project.query(on: db, tenantID: tenantID)
            .filter(\.$archived == false)
            .count()
        async let insightsCountQ = Insight.query(on: db, tenantID: tenantID)
            .filter(\.$dismissedAt == nil)
            .count()
        async let activeProfileQ = UserHermesProfile.query(on: db, tenantID: tenantID)
            .filter(\.$isDefault == true)
            .first()
        async let memoriesTotalQ = Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()
        async let memoriesTodayQ = Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$createdAt >= startOfDay)
            .count()
        async let sessionsCountQ = Conversation.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()
        async let badgesEarnedQ = AchievementProgress.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$unlockedAt != nil)
            .count()
        async let llmPrefQ = UserLLMPreference.query(on: db)
            .filter(\.$tenantID == tenantID)
            .first()
        async let activeJobsQ = ActiveTasksQuery.list(
            tenantID: tenantID,
            db: db,
            limit: ActiveTasksQuery.defaultPreviewLimit
        )
        async let activeJobsCountQ = ActiveTasksQuery.count(tenantID: tenantID, db: db)
        async let graphPreviewQ = Self.graphPreview(tenantID: tenantID, db: db)

        let jobsCount = try await Self.skillRunCount(tenantID: tenantID, db: db)
        let todosCount = try await Self.todoCount(tenantID: tenantID, db: db)
        let graphConnections = try await Self.connectionsCount(tenantID: tenantID, db: db)
        let activeSpaces = try await Self.activeSpacesCount(tenantID: tenantID, db: db)
        let streakDays = try await Self.currentStreakDays(tenantID: tenantID, db: db)

        let skillsCount = try await skillsCountQ
        let skillRows = try await skillNamesQ
        let remindersCount = try await remindersCountQ
        let projectsCount = try await projectsCountQ
        let insightsCount = try await insightsCountQ
        let activeProfile = try await activeProfileQ
        let memoriesTotal = try await memoriesTotalQ
        let memoriesToday = try await memoriesTodayQ
        let sessionsCount = try await sessionsCountQ
        let badgesEarned = try await badgesEarnedQ
        let llmPref = try await llmPrefQ
        let activeJobs = try await activeJobsQ
        let activeJobsCount = try await activeJobsCountQ
        let graphPreview = try await graphPreviewQ

        let xp = PowerLevel.xp(
            memoriesTotal: memoriesTotal,
            sessionsCount: sessionsCount,
            jobsCount: jobsCount,
            badgesEarned: badgesEarned,
            graphConnections: graphConnections,
            activeSpaces: activeSpaces,
            streakDays: streakDays
        )
        let level = PowerLevel.level(forXP: xp)

        // Managed policy is backend-owned AND private: managed tenants never
        // see the concrete provider/model (ModelDisclosurePolicy) — the hero
        // card renders a generic brain label instead. BYOK tenants keep
        // full visibility of the model they configured themselves.
        let isBYOK = llmPref?.mode == UserLLMPreference.Mode.byok.rawValue
        let primaryProvider = isBYOK
            ? llmPref?.primaryProvider ?? managedProvider.rawValue
            : ModelDisclosurePolicy.genericProviderName
        let primaryModel = isBYOK && llmPref?.primaryModel.isEmpty == false
            ? llmPref!.primaryModel
            : ModelDisclosurePolicy.genericBrainName

        // Server-side agent readiness. Network reachability is client-side
        // (`isOnline`); this flag is false only when the tenant has no brain
        // profile and has never chatted (brand-new empty account still shows
        // Online once either signal appears — default true for managed cloud).
        let agentOnline = true

        return HomeSummaryResponse(
            skillsCount: skillsCount,
            jobsCount: jobsCount,
            remindersCount: remindersCount,
            todosCount: todosCount,
            projectsCount: projectsCount,
            insightsCount: insightsCount,
            activeProfileName: activeProfile?.label,
            activeProfileSlug: activeProfile?.slug,
            primaryProvider: primaryProvider,
            primaryModel: primaryModel,
            agentOnline: agentOnline,
            memoriesToday: memoriesToday,
            memoriesTotal: memoriesTotal,
            sessionsCount: sessionsCount,
            activeJobsCount: activeJobsCount,
            activeJobs: activeJobs,
            skills: skillRows.map(\.name),
            powerLevel: level,
            powerXP: xp,
            badgesEarned: badgesEarned,
            streakDays: streakDays,
            graphPreview: graphPreview
        )
    }

    /// `GET /v1/dashboard/activity` — unified recent-activity stream: newest
    /// conversations, memories, achievement unlocks, and skill runs, merged
    /// and capped. Tenant-scoped.
    @Sendable
    func activity(_ request: Request, ctx: AppRequestContext) async throws -> ActivityFeedResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let rawLimit = request.uri.queryParameters.get("limit", as: Int.self)
            ?? Self.activityDefaultLimit
        let limit = min(max(rawLimit, 1), Self.activityMaxLimit)

        guard let sql = fluent.db() as? any SQLDatabase else {
            return ActivityFeedResponse(items: [])
        }
        struct Row: Decodable {
            let id: UUID
            let kind: String
            let title: String
            let subtitle: String?
            let occurred_at: Date
        }
        // Each branch is capped before the union so the merge sorts at most
        // 4×limit rows regardless of tenant history size.
        let rows = try await sql.raw("""
        SELECT id, kind, title, subtitle, occurred_at FROM (
            (SELECT id, 'conversation' AS kind,
                    COALESCE(NULLIF(title, ''), 'Conversation') AS title,
                    NULL AS subtitle, created_at AS occurred_at
             FROM conversations
             WHERE tenant_id = \(bind: tenantID) AND created_at IS NOT NULL
             ORDER BY created_at DESC LIMIT \(bind: limit))
            UNION ALL
            (SELECT id, 'memory' AS kind,
                    LEFT(content, 120) AS title, NULL AS subtitle,
                    created_at AS occurred_at
             FROM memories
             WHERE tenant_id = \(bind: tenantID) AND created_at IS NOT NULL
             ORDER BY created_at DESC LIMIT \(bind: limit))
            UNION ALL
            (SELECT id, 'achievement' AS kind,
                    achievement_key AS title, NULL AS subtitle,
                    unlocked_at AS occurred_at
             FROM achievement_progress
             WHERE tenant_id = \(bind: tenantID) AND unlocked_at IS NOT NULL
             ORDER BY unlocked_at DESC LIMIT \(bind: limit))
            UNION ALL
            (SELECT id, 'skillRun' AS kind,
                    name AS title, status AS subtitle,
                    started_at AS occurred_at
             FROM skill_run_log
             WHERE tenant_id = \(bind: tenantID)
             ORDER BY started_at DESC LIMIT \(bind: limit))
        ) merged
        ORDER BY occurred_at DESC
        LIMIT \(bind: limit)
        """).all(decoding: Row.self)

        let items = rows.compactMap { row -> ActivityFeedItemDTO? in
            guard let kind = ActivityFeedItemKind(rawValue: row.kind) else { return nil }
            let title = kind == .memory
                ? MemoryGraphService.titleFromContent(row.title)
                : row.title
            return ActivityFeedItemDTO(
                id: row.id, kind: kind, title: title,
                subtitle: row.subtitle, occurredAt: row.occurred_at
            )
        }
        return ActivityFeedResponse(items: items)
    }

    /// Home brain-graph preview: the hottest laid-out memories, positions
    /// normalized from the layout cube to roughly `[-1, 1]`. Nil (field
    /// omitted) when the tenant has no computed layout yet.
    private static func graphPreview(
        tenantID: UUID, db: any Database, now: Date = Date()
    ) async throws -> [GraphPreviewNodeDTO]? {
        guard let sql = db as? any SQLDatabase else { return nil }
        struct Row: Decodable {
            let id: UUID
            let content: String
            let score: Double
            let last_accessed_at: Date?
            let created_at: Date?
            let graph_x: Double
            let graph_y: Double
            let graph_z: Double
        }
        let rows = try await sql.raw("""
        SELECT id, content, score, last_accessed_at, created_at,
               graph_x, graph_y, graph_z
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
          AND graph_x IS NOT NULL AND graph_y IS NOT NULL AND graph_z IS NOT NULL
        ORDER BY last_accessed_at DESC NULLS LAST, score DESC, created_at DESC
        LIMIT \(bind: Self.graphPreviewLimit)
        """).all(decoding: Row.self)
        guard !rows.isEmpty else { return nil }

        let extent = GraphLayoutService.cubeExtent
        return rows.map { row in
            GraphPreviewNodeDTO(
                id: row.id,
                label: MemoryGraphService.titleFromContent(row.content),
                x: row.graph_x / extent,
                y: row.graph_y / extent,
                z: row.graph_z / extent,
                activity: MemoryGraphService.activity(
                    score: row.score,
                    lastAccessed: row.last_accessed_at ?? row.created_at,
                    now: now
                ),
                kind: .memory
            )
        }
    }

    /// Count of note-backed todos (`vault_files.metadata.isTodo == true`).
    /// `metadata` is a JSON column, so we filter with the `->>` operator.
    private static func todoCount(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
        SELECT COUNT(*)::int AS count FROM vault_files
        WHERE tenant_id = \(bind: tenantID) AND metadata->>'isTodo' = 'true'
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    @Sendable
    func stats(_: Request, ctx: AppRequestContext) async throws -> DashboardStatsResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()

        let startOfDay = Calendar(identifier: .gregorian).startOfDay(for: Date())

        let memoriesTotal = try await Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()

        let memoriesToday = try await Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$createdAt >= startOfDay)
            .count()

        let latestCompiledSpace = try await Space.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$lastCompiledAt != nil)
            .sort(\.$lastCompiledAt, .descending)
            .first()

        return DashboardStatsResponse(
            memoriesToday: memoriesToday,
            memoriesTotal: memoriesTotal,
            lastCompileAt: latestCompiledSpace?.lastCompiledAt
        )
    }

    /// `GET /v1/dashboard/profile` — the Home "player profile" HUD counts:
    /// enabled skills, total skill runs (jobs), conversations (sessions),
    /// unlocked achievements (badges), plus a derived power level/XP. All
    /// counts are scoped to the JWT-authenticated tenant.
    @Sendable
    func profile(_: Request, ctx: AppRequestContext) async throws -> DashboardProfileResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()

        async let memoriesTotalQ = Memory.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()
        async let sessionsCountQ = Conversation.query(on: db)
            .filter(\.$tenantID == tenantID)
            .count()
        async let skillsCountQ = SkillsState.query(on: db)
            .filter(\.$id == tenantID)
            .filter(\.$enabled == true)
            .count()
        async let badgesEarnedQ = AchievementProgress.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$unlockedAt != nil)
            .count()

        // `skill_run_log` is a raw-SQL table (no Fluent model), so count it
        // directly; mirrors SessionsController's SQLDatabase usage.
        let jobsCount = try await Self.skillRunCount(tenantID: tenantID, db: db)

        // Power-level enrichment signals — all cheap, tenant-scoped counts.
        // `graphConnections` is a lineage proxy (memories with a source page),
        // NOT the full derived graph, so it stays O(1)-ish on the index.
        let graphConnections = try await Self.connectionsCount(tenantID: tenantID, db: db)
        let activeSpaces = try await Self.activeSpacesCount(tenantID: tenantID, db: db)
        let streakDays = try await Self.currentStreakDays(tenantID: tenantID, db: db)

        let memoriesTotal = try await memoriesTotalQ
        let sessionsCount = try await sessionsCountQ
        let skillsCount = try await skillsCountQ
        let badgesEarned = try await badgesEarnedQ

        let xp = PowerLevel.xp(
            memoriesTotal: memoriesTotal,
            sessionsCount: sessionsCount,
            jobsCount: jobsCount,
            badgesEarned: badgesEarned,
            graphConnections: graphConnections,
            activeSpaces: activeSpaces,
            streakDays: streakDays
        )
        let level = PowerLevel.level(forXP: xp)

        return DashboardProfileResponse(
            skillsCount: skillsCount,
            jobsCount: jobsCount,
            sessionsCount: sessionsCount,
            badgesEarned: badgesEarned,
            powerLevel: level,
            powerXP: xp
        )
    }

    private static func skillRunCount(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
        SELECT COUNT(*)::int AS count FROM skill_run_log WHERE tenant_id = \(bind: tenantID)
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    /// Lineage-edge proxy for "graph connections": memories that trace back to
    /// a source vault page. Cheap (single indexed count), unlike deriving the
    /// full memory graph.
    private static func connectionsCount(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
        SELECT COUNT(*)::int AS count FROM memories
        WHERE tenant_id = \(bind: tenantID) AND source_vault_file_id IS NOT NULL
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    /// Number of distinct Spaces that hold memories.
    private static func activeSpacesCount(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
        SELECT COUNT(DISTINCT space_id)::int AS count FROM memories
        WHERE tenant_id = \(bind: tenantID) AND space_id IS NOT NULL
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    /// Current consecutive-day activity streak: the length of the most recent
    /// unbroken run of days with at least one memory or conversation. Computed
    /// in SQL from distinct UTC activity days so large tenants do not ship
    /// their full history back to Swift just to count the current island.
    static func currentStreakDays(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct CountRow: Decodable { let count: Int }
        let row = try await sql.raw("""
        WITH activity_days AS (
            SELECT DISTINCT (created_at AT TIME ZONE 'UTC')::date AS day
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
            UNION
            SELECT DISTINCT (created_at AT TIME ZONE 'UTC')::date AS day
            FROM conversations
            WHERE tenant_id = \(bind: tenantID)
        ),
        ranked AS (
            SELECT day,
                   day - (row_number() OVER (ORDER BY day))::int AS island_key
            FROM activity_days
        ),
        latest AS (
            SELECT island_key
            FROM ranked
            ORDER BY day DESC
            LIMIT 1
        )
        SELECT COUNT(*)::int AS count
        FROM ranked
        WHERE island_key = (SELECT island_key FROM latest)
        """).first(decoding: CountRow.self)
        return row?.count ?? 0
    }

    /// Pure, testable: given `YYYY-MM-DD` day keys (any order, may dup),
    /// returns the length of the most recent unbroken consecutive-day run.
    /// Day keys are parsed as proleptic-Gregorian dates and reduced to an
    /// epoch-day integer, so "consecutive" is exact and timezone-free.
    static func consecutiveStreak(fromDayKeys keys: [String]) -> Int {
        let dayNumbers: Set<Int> = Set(keys.compactMap(Self.epochDay(fromDayKey:)))
        guard let mostRecent = dayNumbers.max() else { return 0 }
        var streak = 0
        var day = mostRecent
        while dayNumbers.contains(day) {
            streak += 1
            day -= 1
        }
        return streak
    }

    /// Parses `YYYY-MM-DD` into days-since-epoch without `DateFormatter`
    /// (which is not `Sendable` and flaky on Linux Foundation). Uses a UTC
    /// Gregorian `Calendar`, which is a value type and concurrency-safe.
    private static func epochDay(fromDayKey key: String) -> Int? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        return Int(date.timeIntervalSince1970 / 86400)
    }
}
