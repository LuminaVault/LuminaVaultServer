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

struct DashboardController {
    let fluent: HummingbirdFluent.Fluent
    let logger: Logger

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("/stats", use: stats)
        router.get("/profile", use: profile)
        router.get("/home", use: home)
    }

    /// `GET /v1/dashboard/home` — one-shot counts for the Home dashboard
    /// cards plus the active Hermes profile, so the landing screen makes a
    /// single request instead of six. All counts are tenant-scoped.
    @Sendable
    func home(_: Request, ctx: AppRequestContext) async throws -> HomeSummaryResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()

        async let skillsCountQ = SkillsState.query(on: db)
            .filter(\.$tenantID == tenantID)
            .filter(\.$enabled == true)
            .count()
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

        let jobsCount = try await Self.skillRunCount(tenantID: tenantID, db: db)
        let todosCount = try await Self.todoCount(tenantID: tenantID, db: db)

        let skillsCount = try await skillsCountQ
        let remindersCount = try await remindersCountQ
        let projectsCount = try await projectsCountQ
        let insightsCount = try await insightsCountQ
        let activeProfile = try await activeProfileQ

        return HomeSummaryResponse(
            skillsCount: skillsCount,
            jobsCount: jobsCount,
            remindersCount: remindersCount,
            todosCount: todosCount,
            projectsCount: projectsCount,
            insightsCount: insightsCount,
            activeProfileName: activeProfile?.label,
            activeProfileSlug: activeProfile?.slug
        )
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
            .filter(\.$tenantID == tenantID)
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
    /// unbroken run of days with at least one memory or conversation. Day keys
    /// are computed in UTC and returned as `YYYY-MM-DD` text to avoid Postgres
    /// `date`→`Date` decoding quirks; the run length is computed in Swift.
    private static func currentStreakDays(tenantID: UUID, db: any Database) async throws -> Int {
        guard let sql = db as? any SQLDatabase else { return 0 }
        struct DayRow: Decodable { let d: String }
        let rows = try await sql.raw("""
        SELECT to_char((created_at AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') AS d FROM memories
        WHERE tenant_id = \(bind: tenantID)
        UNION
        SELECT to_char((created_at AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD') AS d FROM conversations
        WHERE tenant_id = \(bind: tenantID)
        """).all(decoding: DayRow.self)
        return consecutiveStreak(fromDayKeys: rows.map(\.d))
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
