import Foundation
import LuminaVaultShared
import SQLKit

/// Period windows and SQL aggregates for the Home cockpit.
enum DashboardPeriodQuery {
    struct Window {
        let period: DashboardPeriod
        let start: Date
        let end: Date
        let previousStart: Date
        let previousEnd: Date
        let trunc: String
    }

    struct Counts {
        let done: Int
        let captures: Int
        let skillRuns: Int
        let tokens: Int
        let chats: Int
        let jobs: Int
    }

    static func window(period: DashboardPeriod, now: Date = Date()) -> Window {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let startOfToday = calendar.startOfDay(for: now)
        switch period {
        case .today:
            let previousStart = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            return Window(
                period: period,
                start: startOfToday,
                end: now,
                previousStart: previousStart,
                previousEnd: startOfToday,
                trunc: "hour"
            )
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
            let previousStart = calendar.date(byAdding: .day, value: -1, to: start) ?? start
            return Window(
                period: period,
                start: start,
                end: startOfToday,
                previousStart: previousStart,
                previousEnd: start,
                trunc: "hour"
            )
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            let previousStart = calendar.date(byAdding: .day, value: -7, to: start) ?? start
            return Window(
                period: period,
                start: start,
                end: now,
                previousStart: previousStart,
                previousEnd: start,
                trunc: "day"
            )
        case .month:
            let start = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
            let previousStart = calendar.date(byAdding: .day, value: -30, to: start) ?? start
            return Window(
                period: period,
                start: start,
                end: now,
                previousStart: previousStart,
                previousEnd: start,
                trunc: "day"
            )
        }
    }

    static func parsePeriod(_ raw: String?) -> DashboardPeriod {
        raw.flatMap(DashboardPeriod.init(rawValue:)) ?? .today
    }

    static func counts(
        tenantID: UUID,
        start: Date,
        end: Date,
        sql: any SQLDatabase
    ) async throws -> Counts {
        struct Row: Decodable {
            let captures: Int
            let skill_runs: Int
            let done: Int
            let chats: Int
            let tokens: Int
            let jobs: Int
        }
        let row = try await sql.raw("""
        SELECT
            COALESCE((SELECT COUNT(*)::int FROM memories
                      WHERE tenant_id = \(bind: tenantID)
                        AND created_at >= \(bind: start)
                        AND created_at < \(bind: end)), 0) AS captures,
            COALESCE((SELECT COUNT(*)::int FROM skill_run_log
                      WHERE tenant_id = \(bind: tenantID)
                        AND started_at >= \(bind: start)
                        AND started_at < \(bind: end)), 0) AS skill_runs,
            COALESCE((SELECT COUNT(*)::int FROM skill_run_log
                      WHERE tenant_id = \(bind: tenantID)
                        AND started_at >= \(bind: start)
                        AND started_at < \(bind: end)
                        AND LOWER(COALESCE(status, '')) IN ('ok', 'completed', 'succeeded', 'success')), 0) AS done,
            COALESCE((SELECT COUNT(*)::int FROM conversations
                      WHERE tenant_id = \(bind: tenantID)
                        AND created_at >= \(bind: start)
                        AND created_at < \(bind: end)), 0) AS chats,
            COALESCE((SELECT (SUM(COALESCE(mtok_in, 0) + COALESCE(mtok_out, 0)))::int FROM usage_meter
                      WHERE tenant_id = \(bind: tenantID)
                        AND day >= \(bind: start)
                        AND day < \(bind: end)), 0) AS tokens,
            COALESCE((SELECT COUNT(*)::int FROM skill_run_log
                      WHERE tenant_id = \(bind: tenantID)
                        AND started_at >= \(bind: start)
                        AND started_at < \(bind: end)
                        AND LOWER(COALESCE(status, '')) IN ('running', 'queued', 'ok', 'completed')), 0) AS jobs
        """).first(decoding: Row.self)
        return Counts(
            done: row?.done ?? 0,
            captures: row?.captures ?? 0,
            skillRuns: row?.skill_runs ?? 0,
            tokens: row?.tokens ?? 0,
            chats: row?.chats ?? 0,
            jobs: row?.jobs ?? 0
        )
    }

    static func series(
        tenantID: UUID,
        window: Window,
        sql: any SQLDatabase
    ) async throws -> [DashboardSeriesPoint] {
        struct Row: Decodable {
            let bucket: Date
            let value: Int
        }
        let trunc = window.trunc == "hour" ? "hour" : "day"
        let rows = try await sql.raw("""
        SELECT bucket, SUM(value)::int AS value FROM (
            SELECT date_trunc(\(bind: trunc), created_at) AS bucket, COUNT(*)::int AS value
            FROM memories
            WHERE tenant_id = \(bind: tenantID)
              AND created_at >= \(bind: window.start)
              AND created_at < \(bind: window.end)
            GROUP BY 1
            UNION ALL
            SELECT date_trunc(\(bind: trunc), started_at) AS bucket, COUNT(*)::int AS value
            FROM skill_run_log
            WHERE tenant_id = \(bind: tenantID)
              AND started_at >= \(bind: window.start)
              AND started_at < \(bind: window.end)
            GROUP BY 1
            UNION ALL
            SELECT date_trunc(\(bind: trunc), created_at) AS bucket, COUNT(*)::int AS value
            FROM conversations
            WHERE tenant_id = \(bind: tenantID)
              AND created_at >= \(bind: window.start)
              AND created_at < \(bind: window.end)
            GROUP BY 1
        ) merged
        WHERE bucket IS NOT NULL
        GROUP BY bucket
        ORDER BY bucket
        """).all(decoding: Row.self)
        return rows.map { DashboardSeriesPoint(at: $0.bucket, value: $0.value) }
    }
}
