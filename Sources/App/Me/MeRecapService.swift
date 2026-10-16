import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

/// `GET /v1/me/recap` — what the user did over the last 7 or 30 of *their*
/// calendar days. Pure read.
///
/// Days are local to `users.timezone`: every count is bucketed in SQL with
/// `(ts AT TIME ZONE tz)::date`, so a note saved at 23:30 in Los Angeles lands
/// on that evening, not on the next UTC day.
///
/// What counts as what, by `memories.origin_kind` (`MemorySourceKindDTO`):
///
/// - **learned** — memories the model distilled: `knowledge_compile`
///   (`MemoryCompileService`, Sync & Learn) and `chat` / `query`
///   (`MemoryIndexWorker`, kept replies).
/// - **captures** — everything the user put in: `manual` (`POST /v1/memory`,
///   agent connections over MCP), `vault`, `link`, `import`, and `legacy`.
///   `legacy` is not a leftover: it is still what most capture paths write
///   today (note uploads, link captures, files, todos, vault imports,
///   `/v1/memory/upsert`) because they never pass a contribution. A few
///   system writers also write `legacy` (the weekly health correlation, a
///   skill's `memory_emit`, workflow memory nodes) and are counted as
///   captures until they get an origin of their own. `skill` is excluded.
///
/// Captures count memories, not vault files, so a note upload is counted
/// once: `VaultController.upload` creates the note's memory on the first
/// upload and only updates it on later ones, and the vault file row itself
/// is not counted. Rejected memories count for nothing.
struct MeRecapService {
    let fluent: Fluent
    let catalog: AchievementCatalog
    let logger: Logger

    static let learnedKinds: [String] = [
        MemorySourceKindDTO.knowledgeCompile.rawValue,
        MemorySourceKindDTO.chat.rawValue,
        MemorySourceKindDTO.query.rawValue,
    ]
    static let captureKinds: [String] = [
        MemorySourceKindDTO.manual.rawValue,
        MemorySourceKindDTO.vault.rawValue,
        MemorySourceKindDTO.link.rawValue,
        MemorySourceKindDTO.import.rawValue,
        MemorySourceKindDTO.legacy.rawValue,
    ]

    /// Constant origin kinds as a quoted SQL list. Only ever called with the
    /// two static lists above, never with input.
    static func sqlList(_ values: [String]) -> String {
        values.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
    }

    /// The local calendar both windows are cut from.
    struct Window {
        let timezone: String
        /// `yyyy-MM-dd`, oldest first: the previous window then the current one.
        let previousDays: [String]
        let currentDays: [String]
        /// Instants bounding the two windows (start of the oldest previous day,
        /// start of the current window, start of tomorrow).
        let previousStart: Date
        let currentStart: Date
        let end: Date

        init(days: Int, timezone requested: String, now: Date) {
            let zone = TimeZone(identifier: requested) ?? TimeZone(identifier: "UTC")!
            timezone = TimeZone(identifier: requested) == nil ? "UTC" : requested
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let today = calendar.startOfDay(for: now)
            func day(_ offset: Int) -> Date {
                calendar.date(byAdding: .day, value: offset, to: today) ?? today
            }
            func key(_ date: Date) -> String {
                let c = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
            }
            currentDays = (0 ..< days).map { key(day($0 - days + 1)) }
            previousDays = (0 ..< days).map { key(day($0 - 2 * days + 1)) }
            previousStart = day(-2 * days + 1)
            currentStart = day(-days + 1)
            end = day(1)
        }
    }

    func build(user: User, range: AnalyticsRange, now: Date = Date()) async throws -> MeRecapResponse {
        let tenantID = try user.requireID()
        let window = Window(days: range.days, timezone: user.timezone, now: now)
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver required for recap")
        }

        let counts = try await dailyCounts(sql: sql, tenantID: tenantID, window: window)
        func days(_ keys: [String]) -> [RecapDayDTO] {
            keys.map { counts[$0] ?? RecapDayDTO(date: $0) }
        }
        let daily = days(window.currentDays)
        let previousDaily = days(window.previousDays)

        async let streak = DashboardController.currentStreakDays(
            tenantID: tenantID, db: fluent.db(), timezone: window.timezone, asOfDay: window.currentDays.last
        )
        async let previousStreak = DashboardController.currentStreakDays(
            tenantID: tenantID, db: fluent.db(), timezone: window.timezone, asOfDay: window.previousDays.last
        )
        async let kinds = kindCounts(sql: sql, tenantID: tenantID, window: window)
        async let highlightList = highlights(sql: sql, tenantID: tenantID, window: window)

        let totals = try await Self.totals(daily, streakDays: streak)
        return try await MeRecapResponse(
            range: range,
            start: window.currentDays.first ?? "",
            end: window.currentDays.last ?? "",
            timezone: window.timezone,
            totals: totals,
            previousTotals: Self.totals(previousDaily, streakDays: previousStreak),
            daily: daily,
            kinds: kinds,
            highlights: highlightList,
            shareText: Self.shareText(range: range, totals: totals)
        )
    }

    // MARK: - Counts

    private struct DayCountRow: Decodable {
        let day: String
        let captures: Int
        let learned: Int
        let asked: Int
        let reviewed: Int
    }

    /// Per-day counts for both windows in one round trip, keyed by local day.
    private func dailyCounts(sql: any SQLDatabase, tenantID: UUID, window: Window) async throws -> [String: RecapDayDTO] {
        let tz = window.timezone
        let start = window.previousStart
        let end = window.end
        let rows = try await sql.raw("""
        WITH events AS (
            SELECT (created_at AT TIME ZONE \(bind: tz))::date AS day,
                   CASE WHEN origin_kind IN (\(unsafeRaw: Self.sqlList(Self.captureKinds))) THEN 1 ELSE 0 END AS captures,
                   CASE WHEN origin_kind IN (\(unsafeRaw: Self.sqlList(Self.learnedKinds))) THEN 1 ELSE 0 END AS learned,
                   0 AS asked,
                   0 AS reviewed
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND created_at >= \(bind: start) AND created_at < \(bind: end)
              AND review_state <> \(bind: MemoryReviewState.rejected)
            UNION ALL
            SELECT (m.created_at AT TIME ZONE \(bind: tz))::date, 0, 0, 1, 0
            FROM conversation_messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE c.tenant_id = \(bind: tenantID)
              AND m.role = 'user'
              AND m.created_at >= \(bind: start) AND m.created_at < \(bind: end)
            UNION ALL
            SELECT (occurred_at AT TIME ZONE \(bind: tz))::date, 0, 0, 0, 1
            FROM analytics_events
            WHERE vault_id = \(bind: tenantID)
              AND event_name = 'memory_reviewed'
              AND occurred_at >= \(bind: start) AND occurred_at < \(bind: end)
        )
        SELECT day::text AS day,
               SUM(captures)::int AS captures,
               SUM(learned)::int AS learned,
               SUM(asked)::int AS asked,
               SUM(reviewed)::int AS reviewed
        FROM events
        GROUP BY day
        """).all(decoding: DayCountRow.self)
        var byDay: [String: RecapDayDTO] = [:]
        for row in rows {
            byDay[row.day] = RecapDayDTO(
                date: row.day,
                captures: row.captures,
                learned: row.learned,
                asked: row.asked,
                reviewed: row.reviewed
            )
        }
        return byDay
    }

    static func totals(_ days: [RecapDayDTO], streakDays: Int) -> RecapTotalsDTO {
        RecapTotalsDTO(
            captures: days.reduce(0) { $0 + $1.captures },
            learned: days.reduce(0) { $0 + $1.learned },
            asked: days.reduce(0) { $0 + $1.asked },
            reviewed: days.reduce(0) { $0 + $1.reviewed },
            activeDays: days.count(where: { $0.captures + $0.learned + $0.asked + $0.reviewed > 0 }),
            streakDays: streakDays
        )
    }

    private struct KindRow: Decodable {
        let kind: String
        let count: Int
    }

    private func kindCounts(sql: any SQLDatabase, tenantID: UUID, window: Window) async throws -> RecapKindsDTO {
        let rows = try await sql.raw("""
        SELECT kind, COUNT(*)::int AS count
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
          AND created_at >= \(bind: window.currentStart) AND created_at < \(bind: window.end)
          AND review_state <> \(bind: MemoryReviewState.rejected)
          AND kind IS NOT NULL
        GROUP BY kind
        """).all(decoding: KindRow.self)
        let byKind = Dictionary(rows.map { ($0.kind, $0.count) }, uniquingKeysWith: +)
        return RecapKindsDTO(
            preference: byKind[MemoryKindDTO.preference.rawValue] ?? 0,
            decision: byKind[MemoryKindDTO.decision.rawValue] ?? 0,
            fact: byKind[MemoryKindDTO.fact.rawValue] ?? 0,
            note: byKind[MemoryKindDTO.note.rawValue] ?? 0
        )
    }

    // MARK: - Highlights

    static let maxHighlights = 5

    private struct MemoryHighlightRow: Decodable {
        let id: UUID
        let content: String
        let kind: String
        let at: Date
    }

    private struct UnlockRow: Decodable {
        let achievement_key: String
        let unlocked_at: Date
    }

    /// Up to five, newest first: the two newest decisions and preferences,
    /// achievements unlocked in the window, and the memory revisited most.
    /// The most revisited one is kept even when it is not among the newest,
    /// so a busy week does not crowd it out.
    private func highlights(sql: any SQLDatabase, tenantID: UUID, window: Window) async throws -> [RecapHighlightDTO] {
        let start = window.currentStart
        let end = window.end
        let kindRows = try await sql.raw("""
        SELECT id, content, kind, created_at AS at
        FROM (
            SELECT id, content, kind, created_at,
                   row_number() OVER (PARTITION BY kind ORDER BY created_at DESC) AS rn
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND created_at >= \(bind: start) AND created_at < \(bind: end)
              AND review_state <> \(bind: MemoryReviewState.rejected)
              AND kind IN ('decision', 'preference')
        ) ranked
        WHERE rn <= 2
        """).all(decoding: MemoryHighlightRow.self)

        let unlocks = try await sql.raw("""
        SELECT achievement_key, unlocked_at
        FROM achievement_progress
        WHERE tenant_id = \(bind: tenantID)
          AND unlocked_at >= \(bind: start) AND unlocked_at < \(bind: end)
        ORDER BY unlocked_at DESC
        LIMIT \(bind: Self.maxHighlights)
        """).all(decoding: UnlockRow.self)

        // "Revisited" = reviewed by the user (`review_count`), then drawn on
        // by Lumina (`query_hit_count`), touched within the window. Lifetime
        // counters: the window only decides eligibility.
        let revisited = try await sql.raw("""
        SELECT id, content, 'mostRevisited' AS kind,
               GREATEST(
                   COALESCE(last_reviewed_at, '-infinity'::timestamptz),
                   COALESCE(last_accessed_at, '-infinity'::timestamptz)
               ) AS at
        FROM memories
        WHERE tenant_id = \(bind: tenantID)
          AND review_state <> \(bind: MemoryReviewState.rejected)
          AND review_count + query_hit_count > 0
          AND (
              (last_reviewed_at >= \(bind: start) AND last_reviewed_at < \(bind: end))
              OR (last_accessed_at >= \(bind: start) AND last_accessed_at < \(bind: end))
          )
        ORDER BY review_count DESC, query_hit_count DESC, at DESC
        LIMIT 1
        """).first(decoding: MemoryHighlightRow.self)

        var others: [RecapHighlightDTO] = kindRows.map {
            RecapHighlightDTO(
                kind: RecapHighlightKind(rawValue: $0.kind) ?? .unknown,
                refId: $0.id.uuidString,
                title: MeTodayService.titlePreview(from: $0.content),
                date: $0.at
            )
        }
        let byKey = catalog.subsByKey
        others += unlocks.map {
            RecapHighlightDTO(
                kind: .achievement,
                refId: $0.achievement_key,
                title: byKey[$0.achievement_key]?.label ?? $0.achievement_key,
                date: $0.unlocked_at
            )
        }
        others.sort { $0.date > $1.date }

        var picked: [RecapHighlightDTO] = []
        if let revisited {
            picked.append(RecapHighlightDTO(
                kind: .mostRevisited,
                refId: revisited.id.uuidString,
                title: MeTodayService.titlePreview(from: revisited.content),
                date: revisited.at
            ))
        }
        picked += others.prefix(Self.maxHighlights - picked.count)
        return picked.sorted { $0.date > $1.date }
    }

    // MARK: - Share text

    /// Numbers only — never memory content, titles or achievement names, so
    /// it is safe to paste anywhere. Zero parts are left out, except captures,
    /// which always lead the sentence.
    static func shareText(range: AnalyticsRange, totals: RecapTotalsDTO) -> String {
        func plural(_ n: Int, _ one: String, _ many: String) -> String {
            "\(n) \(n == 1 ? one : many)"
        }
        var parts = [plural(totals.captures, "capture", "captures")]
        if totals.learned > 0 {
            parts.append(plural(totals.learned, "thing learned", "things learned"))
        }
        if totals.asked > 0 {
            parts.append(plural(totals.asked, "question asked", "questions asked"))
        }
        if totals.streakDays > 0 {
            parts.append("a \(totals.streakDays)-day streak")
        }
        return "My last \(range.days) days on LuminaVault: \(parts.joined(separator: ", "))."
    }
}
