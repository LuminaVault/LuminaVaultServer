import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import LuminaVaultShared
import ServiceLifecycle
import SQLKit

/// Weekly "where is retrieval leaking?" roll-up (the article's "measure where
/// time leaks", applied to pgvector retrieval instead of a filesystem walk).
///
/// `ServiceLifecycle.Service` shaped like `SynthesisWorker`: wakes every
/// `tickInterval` and, at Sunday 05:00 GMT (after SynthesisWorker's 02:00, so
/// the week's telemetry has settled), aggregates each tenant's
/// `RetrievalTelemetryEvent` rows over the trailing 7 days into one
/// `RetrievalLeakReport` row. Idempotent via the report's UNIQUE window index;
/// a re-run in the same window inserts nothing. Optionally mirrors the report
/// to an `Insight(section: .patterns)` for the iOS Analytics surface.
///
/// Single-replica (same caveat as SynthesisWorker). Off-hot-path, read-mostly.
actor RetrievalLeakReportWorker: Service {
    let fluent: Fluent
    let logger: Logger
    let surfaceInsight: Bool
    let tickInterval: Duration

    init(
        fluent: Fluent,
        logger: Logger,
        surfaceInsight: Bool = false,
        tickInterval: Duration = .seconds(3600)
    ) {
        self.fluent = fluent
        self.logger = logger
        self.surfaceInsight = surfaceInsight
        self.tickInterval = tickInterval
    }

    func run() async throws {
        logger.info("retrieval.leak_report worker started (tick=\(tickInterval))")
        while !Task.isCancelled {
            do { try await tick(at: Date()) }
            catch { logger.warning("retrieval.leak_report tick error: \(error)") }
            try? await Task.sleep(for: tickInterval)
        }
    }

    /// Single tick. Exposed so tests can drive a specific instant. Returns the
    /// number of report rows inserted.
    @discardableResult
    func tick(at now: Date) async throws -> Int {
        guard Self.hourComponent(of: now) == 5, Self.weekdayComponent(of: now) == 1 else {
            return 0
        }
        return try await runForAllTenants(now: now)
    }

    func runForAllTenants(now: Date) async throws -> Int {
        let window = Self.weeklyWindow(endingAt: now)
        let users = try await User.query(on: fluent.db()).all()
        var inserted = 0
        for user in users {
            let tenantID = try user.requireID()
            do {
                if try await runLeakJob(tenantID: tenantID, window: window) {
                    inserted += 1
                }
            } catch {
                logger.warning("retrieval.leak_report tenant=\(tenantID) error: \(error)")
            }
        }
        return inserted
    }

    /// One tenant's weekly report. Returns true when a row was inserted, false
    /// when skipped (already reported for this window, or no telemetry).
    @discardableResult
    func runLeakJob(tenantID: UUID, window: Period) async throws -> Bool {
        let existing = try await RetrievalLeakReport.query(on: fluent.db(), tenantID: tenantID)
            .filter(\.$periodStart == window.start)
            .filter(\.$periodEnd == window.end)
            .first()
        if existing != nil {
            return false
        }

        guard let sql = fluent.db() as? any SQLDatabase else { return false }

        let totals = try await sql.raw("""
        SELECT
            COUNT(*) AS total,
            COUNT(*) FILTER (WHERE zero_hit) AS zero_hits,
            AVG(top_distance) FILTER (WHERE NOT zero_hit) AS mean_top
        FROM retrieval_telemetry_events
        WHERE tenant_id = \(bind: tenantID)
          AND created_at >= \(bind: window.start)
          AND created_at < \(bind: window.end)
        """).first(decoding: TotalsRow.self)

        guard let totals, totals.total > 0 else { return false }

        // Worst source = highest zero-hit rate among sources with ≥1 retrieval.
        let worst = try await sql.raw("""
        SELECT source_path,
               COUNT(*) AS n,
               COUNT(*) FILTER (WHERE zero_hit) AS zeros
        FROM retrieval_telemetry_events
        WHERE tenant_id = \(bind: tenantID)
          AND created_at >= \(bind: window.start)
          AND created_at < \(bind: window.end)
        GROUP BY source_path
        ORDER BY (COUNT(*) FILTER (WHERE zero_hit))::float / COUNT(*) DESC, n DESC
        LIMIT 1
        """).first(decoding: WorstRow.self)

        let zeroRate = Double(totals.zeroHits) / Double(totals.total)
        let report = RetrievalLeakReport(
            tenantID: tenantID,
            periodStart: window.start,
            periodEnd: window.end,
            totalRetrievals: totals.total,
            zeroHitCount: totals.zeroHits,
            zeroHitRate: zeroRate,
            meanTopDistance: totals.meanTop,
            worstSource: worst?.sourcePath
        )
        do {
            try await report.create(on: fluent.db())
        } catch {
            // Lost the idempotency race (concurrent run / restart) — the UNIQUE
            // window index rejected the duplicate. Treat as already-done.
            logger.debug("retrieval.leak_report duplicate tenant=\(tenantID): \(error)")
            return false
        }

        logger.info("""
        retrieval.leak_report tenant=\(tenantID) total=\(totals.total) \
        zeroHitRate=\(String(format: "%.3f", zeroRate)) \
        meanTopDistance=\(totals.meanTop.map { String(format: "%.3f", $0) } ?? "n/a") \
        worst=\(worst?.sourcePath ?? "n/a")
        """)

        if surfaceInsight {
            let insight = Insight(
                tenantID: tenantID,
                section: .patterns,
                headline: "Retrieval health this week",
                summary: Self.insightSummary(
                    total: totals.total, zeroRate: zeroRate,
                    meanTop: totals.meanTop, worst: worst?.sourcePath
                ),
                periodStart: window.start,
                periodEnd: window.end
            )
            try? await insight.create(on: fluent.db())
        }
        return true
    }

    static func insightSummary(total: Int, zeroRate: Double, meanTop: Double?, worst: String?) -> String {
        let pct = Int((zeroRate * 100).rounded())
        var s = "\(total) retrievals; \(pct)% found nothing"
        if let meanTop {
            s += "; avg best match \(String(format: "%.2f", meanTop))"
        }
        if let worst, zeroRate > 0 {
            s += "; weakest path: \(worst)"
        }
        return s + "."
    }

    // MARK: - Window math (GMT, mirrors SynthesisWorker)

    struct Period: Equatable {
        let start: Date
        let end: Date
    }

    static func weeklyWindow(endingAt now: Date) -> Period {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let endOfDay = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -7, to: endOfDay) ?? endOfDay
        return Period(start: start, end: endOfDay)
    }

    static func hourComponent(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.hour, from: date)
    }

    /// 1 = Sunday in `Calendar.gregorian`.
    static func weekdayComponent(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.component(.weekday, from: date)
    }

    private struct TotalsRow: Decodable {
        let total: Int
        let zeroHits: Int
        let meanTop: Double?
        enum CodingKeys: String, CodingKey {
            case total
            case zeroHits = "zero_hits"
            case meanTop = "mean_top"
        }
    }

    private struct WorstRow: Decodable {
        let sourcePath: String
        enum CodingKeys: String, CodingKey {
            case sourcePath = "source_path"
        }
    }
}
