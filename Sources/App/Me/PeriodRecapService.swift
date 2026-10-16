import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// `GET /v1/me/recap/period` — the year or month in review. Pure read, apart
/// from claiming the one model-written card (`PeriodRecapThemes.swift`).
///
/// Counting follows `MeRecapService`: captures and learned by
/// `memories.origin_kind`, rejected memories count for nothing, questions are
/// the user's chat messages, and every day and hour is local to
/// `users.timezone`. Reviews are left out: they live in `analytics_events`,
/// which keeps 90 days, so a year would undercount them.
struct PeriodRecapService {
    let fluent: Fluent
    let catalog: AchievementCatalog
    /// Nil turns the themes card off (`status: disabled`).
    let themes: (store: PeriodRecapThemesStore, scheduler: any PeriodRecapThemesScheduling)?
    let logger: Logger

    func build(user: User, kind: RecapPeriodKind, year: Int, month: Int?, now: Date = Date()) async throws -> PeriodRecapResponse {
        guard let window = PeriodRecapWindow(kind: kind, year: year, month: month, timezone: user.timezone, now: now) else {
            throw HTTPError(.badRequest, message: "invalid recap period")
        }
        let userID = try user.requireID()
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for recap")
        }

        var inputs = PeriodRecapBuilder.Inputs()
        if !window.isFuture {
            inputs = try await read(sql: sql, userID: userID, window: window)
        }

        let current = window.days.reduce(into: PeriodRecapBuilder.DayCounts()) { total, day in
            let counts = inputs.days[day.key] ?? .init()
            total.captures += counts.captures
            total.learned += counts.learned
            total.asked += counts.asked
        }
        let eligible = PeriodRecapBuilder.unavailableReason(
            window: window,
            accountCreatedAt: user.createdAt,
            inputs: inputs
        ) == nil
        let themesCard = eligible
            ? await themesCard(userID: userID, window: window, inputs: inputs, current: current, now: now)
            : nil
        return PeriodRecapBuilder.build(
            window: window,
            accountCreatedAt: user.createdAt,
            inputs: inputs,
            themes: themesCard,
            now: now
        )
    }

    // MARK: - Themes

    /// Never throws: a failing cache read shows the counted fallback rather
    /// than failing the whole recap.
    private func themesCard(
        userID: UUID,
        window: PeriodRecapWindow,
        inputs: PeriodRecapBuilder.Inputs,
        current: PeriodRecapBuilder.DayCounts,
        now: Date
    ) async -> RecapThemesCardDTO {
        let fallback = PeriodRecapBuilder.fallbackSentence(window: window, topTags: inputs.topTags, memories: current.memories)
        guard let themes else {
            return PeriodRecapThemesPolicy.card(row: nil, claimed: false, enabled: false, fallback: fallback, now: now)
        }
        do {
            let row = try await themes.store.load(userID: userID, periodKey: window.periodKey)
            var claimed = false
            if PeriodRecapThemesPolicy.needsGeneration(row: row, isComplete: window.isComplete, now: now) {
                claimed = try await themes.store.claim(userID: userID, periodKey: window.periodKey, now: now)
                if claimed {
                    let series = PeriodRecapBuilder.series(window: window, days: inputs.days)
                    themes.scheduler.schedule(PeriodRecapThemesJob(
                        userID: userID,
                        periodKey: window.periodKey,
                        start: window.start,
                        end: window.end,
                        input: PeriodRecapThemesInput(
                            periodName: PeriodRecapBuilder.periodName(window),
                            kind: window.kind,
                            memories: current.memories,
                            asked: current.asked,
                            topTags: inputs.topTags,
                            topSpace: inputs.topSpace?.label,
                            persona: PeriodRecapBuilder.rhythm(hourCounts: inputs.hourCounts)?.persona,
                            busiest: PeriodRecapBuilder.peak(window: window, days: inputs.days, series: series)?.busiest.key
                        )
                    ))
                }
            }
            return PeriodRecapThemesPolicy.card(row: row, claimed: claimed, enabled: true, fallback: fallback, now: now)
        } catch {
            logger.warning("recap themes cache failed: \(error)")
            return PeriodRecapThemesPolicy.card(row: nil, claimed: false, enabled: true, fallback: fallback, now: now)
        }
    }

    // MARK: - Reads

    private func read(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> PeriodRecapBuilder.Inputs {
        async let daily = dailyCounts(sql: sql, userID: userID, window: window)
        async let hours = hourCounts(sql: sql, userID: userID, window: window)
        async let kinds = kindCounts(sql: sql, userID: userID, window: window)
        async let tags = topTags(sql: sql, userID: userID, window: window)
        async let space = topSpace(sql: sql, userID: userID, window: window)
        async let conversations = conversationCount(sql: sql, userID: userID, window: window)
        async let skills = skillRuns(sql: sql, userID: userID, window: window)
        async let achievements = achievements(sql: sql, userID: userID, window: window)
        async let first = firstCapture(sql: sql, userID: userID, window: window)

        let (days, previous) = try await daily
        let skillResult = try await skills
        return try await PeriodRecapBuilder.Inputs(
            days: days,
            previous: previous,
            hourCounts: hours,
            kinds: kinds,
            topTags: tags,
            topSpace: space,
            conversations: conversations,
            skillRuns: skillResult.runs,
            topSkill: skillResult.top,
            achievements: achievements,
            firstCapture: first
        )
    }

    private static var captureList: String {
        MeRecapService.sqlList(MeRecapService.captureKinds)
    }

    private static var learnedList: String {
        MeRecapService.sqlList(MeRecapService.learnedKinds)
    }

    private struct DayRow: Decodable {
        let day: String
        let captures: Int
        let learned: Int
        let asked: Int
    }

    /// Per-day counts for the period, and totals for the comparison window,
    /// in one round trip.
    private func dailyCounts(
        sql: any SQLDatabase,
        userID: UUID,
        window: PeriodRecapWindow
    ) async throws -> ([String: PeriodRecapBuilder.DayCounts], PeriodRecapBuilder.DayCounts) {
        let tz = window.timezone
        let rows = try await sql.raw("""
        WITH events AS (
            SELECT created_at AS at,
                   CASE WHEN origin_kind IN (\(unsafeRaw: Self.captureList)) THEN 1 ELSE 0 END AS captures,
                   CASE WHEN origin_kind IN (\(unsafeRaw: Self.learnedList)) THEN 1 ELSE 0 END AS learned,
                   0 AS asked
            FROM memories
            WHERE tenant_id = \(bind: userID)
              AND review_state <> \(bind: MemoryReviewState.rejected)
              AND ((created_at >= \(bind: window.start) AND created_at < \(bind: window.end))
                OR (created_at >= \(bind: window.previousStart) AND created_at < \(bind: window.previousEnd)))
            UNION ALL
            SELECT m.created_at, 0, 0, 1
            FROM conversation_messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE c.tenant_id = \(bind: userID)
              AND m.role = 'user'
              AND ((m.created_at >= \(bind: window.start) AND m.created_at < \(bind: window.end))
                OR (m.created_at >= \(bind: window.previousStart) AND m.created_at < \(bind: window.previousEnd)))
        )
        SELECT (at AT TIME ZONE \(bind: tz))::date::text AS day,
               SUM(captures)::int AS captures,
               SUM(learned)::int AS learned,
               SUM(asked)::int AS asked
        FROM events
        GROUP BY 1
        """).all(decoding: DayRow.self)

        let startKey = window.startKey
        var current: [String: PeriodRecapBuilder.DayCounts] = [:]
        var previous = PeriodRecapBuilder.DayCounts()
        for row in rows {
            if !startKey.isEmpty, row.day >= startKey {
                current[row.day] = .init(captures: row.captures, learned: row.learned, asked: row.asked)
            } else {
                previous.captures += row.captures
                previous.learned += row.learned
                previous.asked += row.asked
            }
        }
        return (current, previous)
    }

    private struct HourRow: Decodable {
        let hour: Int
        let count: Int
    }

    /// When the user shows up: their captures and the messages they sent.
    /// Learned memories are left out; a background compile wrote them.
    private func hourCounts(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> [Int] {
        let tz = window.timezone
        let rows = try await sql.raw("""
        SELECT EXTRACT(hour FROM (at AT TIME ZONE \(bind: tz)))::int AS hour, COUNT(*)::int AS count
        FROM (
            SELECT created_at AS at
            FROM memories
            WHERE tenant_id = \(bind: userID)
              AND created_at >= \(bind: window.start) AND created_at < \(bind: window.end)
              AND review_state <> \(bind: MemoryReviewState.rejected)
              AND origin_kind IN (\(unsafeRaw: Self.captureList))
            UNION ALL
            SELECT m.created_at
            FROM conversation_messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE c.tenant_id = \(bind: userID)
              AND m.role = 'user'
              AND m.created_at >= \(bind: window.start) AND m.created_at < \(bind: window.end)
        ) events
        GROUP BY 1
        """).all(decoding: HourRow.self)
        var hours = Array(repeating: 0, count: 24)
        for row in rows where (0 ..< 24).contains(row.hour) {
            hours[row.hour] = row.count
        }
        return hours
    }

    private struct LabelRow: Decodable {
        let label: String
        let count: Int
    }

    private func kindCounts(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> [RecapCountDTO] {
        try await sql.raw("""
        SELECT kind AS label, COUNT(*)::int AS count
        FROM memories
        WHERE tenant_id = \(bind: userID)
          AND created_at >= \(bind: window.start) AND created_at < \(bind: window.end)
          AND review_state <> \(bind: MemoryReviewState.rejected)
          AND kind IS NOT NULL
        GROUP BY kind
        ORDER BY count DESC, label ASC
        """).all(decoding: LabelRow.self).map { RecapCountDTO(label: $0.label, count: $0.count) }
    }

    static let maxTags = 5

    private func topTags(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> [RecapCountDTO] {
        try await sql.raw("""
        SELECT lower(t.tag) AS label, COUNT(*)::int AS count
        FROM memories, unnest(memories.tags) AS t(tag)
        WHERE memories.tenant_id = \(bind: userID)
          AND memories.created_at >= \(bind: window.start) AND memories.created_at < \(bind: window.end)
          AND memories.review_state <> \(bind: MemoryReviewState.rejected)
          AND btrim(t.tag) <> ''
        GROUP BY lower(t.tag)
        ORDER BY count DESC, label ASC
        LIMIT \(bind: Self.maxTags)
        """).all(decoding: LabelRow.self).map { RecapCountDTO(label: $0.label, count: $0.count) }
    }

    private func topSpace(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> RecapCountDTO? {
        try await sql.raw("""
        SELECT s.name AS label, COUNT(*)::int AS count
        FROM memories m
        JOIN spaces s ON s.id = m.space_id
        WHERE m.tenant_id = \(bind: userID)
          AND m.created_at >= \(bind: window.start) AND m.created_at < \(bind: window.end)
          AND m.review_state <> \(bind: MemoryReviewState.rejected)
        GROUP BY s.id, s.name
        ORDER BY count DESC, label ASC
        LIMIT 1
        """).first(decoding: LabelRow.self).map { RecapCountDTO(label: $0.label, count: $0.count) }
    }

    private struct CountRow: Decodable {
        let count: Int
    }

    private func conversationCount(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> Int {
        try await sql.raw("""
        SELECT COUNT(*)::int AS count
        FROM conversations
        WHERE tenant_id = \(bind: userID)
          AND created_at >= \(bind: window.start) AND created_at < \(bind: window.end)
        """).first(decoding: CountRow.self)?.count ?? 0
    }

    private struct SkillRow: Decodable {
        let label: String
        let count: Int
        let total: Int
    }

    private func skillRuns(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> (runs: Int, top: RecapCountDTO?) {
        let row = try await sql.raw("""
        SELECT name AS label, COUNT(*)::int AS count, (SUM(COUNT(*)) OVER ())::int AS total
        FROM skill_run_log
        WHERE tenant_id = \(bind: userID)
          AND started_at >= \(bind: window.start) AND started_at < \(bind: window.end)
        GROUP BY name
        ORDER BY count DESC, label ASC
        LIMIT 1
        """).first(decoding: SkillRow.self)
        guard let row else { return (0, nil) }
        return (row.total, RecapCountDTO(label: row.label, count: row.count))
    }

    private struct UnlockRow: Decodable {
        let achievement_key: String
        let unlocked_at: Date
    }

    private func achievements(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> [RecapAchievementDTO] {
        let rows = try await sql.raw("""
        SELECT achievement_key, unlocked_at
        FROM achievement_progress
        WHERE tenant_id = \(bind: userID)
          AND unlocked_at >= \(bind: window.start) AND unlocked_at < \(bind: window.end)
        ORDER BY unlocked_at ASC
        """).all(decoding: UnlockRow.self)
        let byKey = catalog.subsByKey
        return rows.map {
            RecapAchievementDTO(
                key: $0.achievement_key,
                title: byKey[$0.achievement_key]?.label ?? $0.achievement_key,
                unlockedAt: $0.unlocked_at
            )
        }
    }

    private struct FirstRow: Decodable {
        let id: UUID
        let content: String
        let day: String
    }

    private func firstCapture(sql: any SQLDatabase, userID: UUID, window: PeriodRecapWindow) async throws -> RecapFirstCaptureDTO? {
        try await sql.raw("""
        SELECT id, content, (created_at AT TIME ZONE \(bind: window.timezone))::date::text AS day
        FROM memories
        WHERE tenant_id = \(bind: userID)
          AND created_at >= \(bind: window.start) AND created_at < \(bind: window.end)
          AND review_state <> \(bind: MemoryReviewState.rejected)
          AND origin_kind IN (\(unsafeRaw: Self.captureList))
        ORDER BY created_at ASC
        LIMIT 1
        """).first(decoding: FirstRow.self).map {
            RecapFirstCaptureDTO(memoryId: $0.id, date: $0.day, title: MeTodayService.titlePreview(from: $0.content))
        }
    }
}
