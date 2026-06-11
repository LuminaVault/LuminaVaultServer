import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

extension MeUsageResponse: @retroactive ResponseEncodable {}

struct UsageMetricsService {
    let fluent: Fluent
    let logger: Logger

    init(fluent: Fluent, logger: Logger = Logger(label: "lv.billing.usage-metrics")) {
        self.fluent = fluent
        self.logger = logger
    }

    func currentMonthUsage(for user: User, now: Date = Date()) async throws -> MeUsageResponse {
        let tenantID = try user.requireID()
        let period = Self.currentUTCMonth(containing: now)

        async let storageBytes = storageBytes(tenantID: tenantID)
        async let metered = usageMeterTotals(tenantID: tenantID, period: period)
        async let events = eventTotals(tenantID: tenantID, period: period)
        async let daily = dailyUsage(tenantID: tenantID, period: period)

        let meterTotals = try await metered
        let eventTotals = try await events

        return try await MeUsageResponse(
            tier: UserTier(rawValue: user.tier) ?? .trial,
            periodStart: period.start,
            periodEnd: period.end,
            generatedAt: now,
            storageBytes: storageBytes,
            tokensIn: meterTotals.tokensIn,
            tokensOut: meterTotals.tokensOut,
            tokensTotal: meterTotals.tokensIn + meterTotals.tokensOut,
            ttsCharacters: meterTotals.ttsCharacters,
            compileRuns: eventTotals.compileRuns,
            compileFiles: eventTotals.compileFiles,
            daily: daily
        )
    }

    func recordMemoryCompile(tenantID: UUID, runID: UUID, files: Int) async {
        await recordEvent(
            tenantID: tenantID,
            metric: "memory_compile_run",
            amount: 1,
            source: "memory_compile",
            idempotencyKey: "memory_compile_run:\(runID.uuidString)",
            metadata: #"{"run_id":"\#(runID.uuidString)"}"#
        )
        await recordEvent(
            tenantID: tenantID,
            metric: "memory_compile_file",
            amount: max(0, files),
            source: "memory_compile",
            idempotencyKey: "memory_compile_file:\(runID.uuidString)",
            metadata: #"{"run_id":"\#(runID.uuidString)"}"#
        )
    }

    private func recordEvent(
        tenantID: UUID,
        metric: String,
        amount: Int,
        source: String,
        idempotencyKey: String,
        metadata: String
    ) async {
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("usage_events requires SQL driver, skipping record")
            return
        }
        do {
            try await sql.raw("""
            INSERT INTO usage_events (tenant_id, metric, amount, source, idempotency_key, metadata)
            VALUES (\(bind: tenantID), \(bind: metric), \(bind: Int64(amount)), \(bind: source),
                    \(bind: idempotencyKey), \(bind: metadata)::jsonb)
            ON CONFLICT (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL
            DO UPDATE SET amount = EXCLUDED.amount
            """).run()
        } catch {
            logger.error("usage_events record failed", metadata: [
                "tenant_id": .string(tenantID.uuidString),
                "metric": .string(metric),
                "error": .string("\(error)"),
            ])
        }
    }

    private func storageBytes(tenantID: UUID) async throws -> Int64 {
        struct Row: Decodable { let total: Int64 }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver unavailable")
        }
        let row = try await sql.raw("""
        SELECT COALESCE(SUM(size_bytes), 0)::bigint AS total
        FROM vault_files
        WHERE tenant_id = \(bind: tenantID)
        """).first(decoding: Row.self)
        return row?.total ?? 0
    }

    private func usageMeterTotals(tenantID: UUID, period: Period) async throws -> MeterTotals {
        struct Row: Decodable {
            let tokensIn: Int64
            let tokensOut: Int64
            let ttsCharacters: Int64

            enum CodingKeys: String, CodingKey {
                case tokensIn = "tokens_in"
                case tokensOut = "tokens_out"
                case ttsCharacters = "tts_characters"
            }
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver unavailable")
        }
        let row = try await sql.raw("""
        SELECT
            COALESCE(SUM(mtok_in), 0)::bigint AS tokens_in,
            COALESCE(SUM(mtok_out), 0)::bigint AS tokens_out,
            COALESCE(SUM(chars_out), 0)::bigint AS tts_characters
        FROM usage_meter
        WHERE tenant_id = \(bind: tenantID)
          AND day >= \(bind: period.start)
          AND day < \(bind: period.end)
        """).first(decoding: Row.self)
        return MeterTotals(
            tokensIn: row?.tokensIn ?? 0,
            tokensOut: row?.tokensOut ?? 0,
            ttsCharacters: row?.ttsCharacters ?? 0
        )
    }

    private func eventTotals(tenantID: UUID, period: Period) async throws -> EventTotals {
        struct Row: Decodable {
            let compileRuns: Int64
            let compileFiles: Int64

            enum CodingKeys: String, CodingKey {
                case compileRuns = "compile_runs"
                case compileFiles = "compile_files"
            }
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver unavailable")
        }
        let row = try await sql.raw("""
        SELECT
            COALESCE(SUM(amount) FILTER (WHERE metric = 'memory_compile_run'), 0)::bigint AS compile_runs,
            COALESCE(SUM(amount) FILTER (WHERE metric = 'memory_compile_file'), 0)::bigint AS compile_files
        FROM usage_events
        WHERE tenant_id = \(bind: tenantID)
          AND occurred_at >= \(bind: period.start)
          AND occurred_at < \(bind: period.end)
        """).first(decoding: Row.self)
        return EventTotals(
            compileRuns: row?.compileRuns ?? 0,
            compileFiles: row?.compileFiles ?? 0
        )
    }

    private func dailyUsage(tenantID: UUID, period: Period) async throws -> [UsageDailyPointDTO] {
        struct Row: Decodable {
            let day: Date
            let tokensIn: Int64
            let tokensOut: Int64
            let ttsCharacters: Int64
            let compileRuns: Int64
            let compileFiles: Int64

            enum CodingKeys: String, CodingKey {
                case day
                case tokensIn = "tokens_in"
                case tokensOut = "tokens_out"
                case ttsCharacters = "tts_characters"
                case compileRuns = "compile_runs"
                case compileFiles = "compile_files"
            }
        }
        guard let sql = fluent.db() as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL driver unavailable")
        }
        let rows = try await sql.raw("""
        WITH meter AS (
            SELECT day::timestamptz AS day,
                   SUM(mtok_in) AS tokens_in,
                   SUM(mtok_out) AS tokens_out,
                   SUM(chars_out) AS tts_characters,
                   0::bigint AS compile_runs,
                   0::bigint AS compile_files
            FROM usage_meter
            WHERE tenant_id = \(bind: tenantID)
              AND day >= \(bind: period.start)
              AND day < \(bind: period.end)
            GROUP BY day
            UNION ALL
            SELECT date_trunc('day', occurred_at) AS day,
                   0::bigint AS tokens_in,
                   0::bigint AS tokens_out,
                   0::bigint AS tts_characters,
                   SUM(amount) FILTER (WHERE metric = 'memory_compile_run') AS compile_runs,
                   SUM(amount) FILTER (WHERE metric = 'memory_compile_file') AS compile_files
            FROM usage_events
            WHERE tenant_id = \(bind: tenantID)
              AND occurred_at >= \(bind: period.start)
              AND occurred_at < \(bind: period.end)
            GROUP BY date_trunc('day', occurred_at)
        )
        SELECT day,
               COALESCE(SUM(tokens_in), 0)::bigint AS tokens_in,
               COALESCE(SUM(tokens_out), 0)::bigint AS tokens_out,
               COALESCE(SUM(tts_characters), 0)::bigint AS tts_characters,
               COALESCE(SUM(compile_runs), 0)::bigint AS compile_runs,
               COALESCE(SUM(compile_files), 0)::bigint AS compile_files
        FROM meter
        GROUP BY day
        ORDER BY day ASC
        """).all(decoding: Row.self)
        return rows.map {
            UsageDailyPointDTO(
                day: $0.day,
                tokensIn: $0.tokensIn,
                tokensOut: $0.tokensOut,
                ttsCharacters: $0.ttsCharacters,
                compileRuns: $0.compileRuns,
                compileFiles: $0.compileFiles
            )
        }
    }

    private struct MeterTotals {
        let tokensIn: Int64
        let tokensOut: Int64
        let ttsCharacters: Int64
    }

    private struct EventTotals {
        let compileRuns: Int64
        let compileFiles: Int64
    }

    private struct Period {
        let start: Date
        let end: Date
    }

    private static func currentUTCMonth(containing date: Date) -> Period {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        let start = calendar.date(from: components) ?? date
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return Period(start: start, end: end)
    }
}
