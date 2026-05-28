import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared
import SQLKit

// MARK: - Server-side conformances

extension HealthIngestResponse: ResponseEncodable {}
// HER-118: HealthEventDTO + HealthListResponse + HealthDailyResponse are
// shared wire types (LuminaVaultShared v0.38.0); server-side
// ResponseEncodable conformances live here so the read handlers can
// return them directly. The legacy server-local copies that lived in
// HealthDTOs.swift were removed in HER-118 — the `metadata` field they
// carried is not consumed by any client surface; sample metadata is
// retained on the DB row (`HealthEvent.metadata`) for future read needs.
extension HealthEventDTO: ResponseEncodable {}
extension HealthListResponse: ResponseEncodable {}
extension HealthDailyResponse: ResponseEncodable {}

// HER-202 — non-throwing accessor mirroring `Memory.savedID`
// (`Sources/App/Memory/MemoryController.swift:29-39`). Fluent's `id`
// is structurally optional but any post-query row always has it set.
extension HealthEvent {
    var savedID: UUID {
        guard let id else {
            preconditionFailure("HealthEvent.savedID called on unsaved HealthEvent — use requireID() before persistence")
        }
        return id
    }
}

extension HealthEventDTO {
    /// Non-throwing converter for a HealthEvent fetched from the DB. Mirrors
    /// `MemoryDTO.fromMemory` so call sites don't wrap every DTO mapping in `try`.
    static func fromHealthEvent(_ row: HealthEvent) -> HealthEventDTO {
        HealthEventDTO(
            id: row.savedID,
            type: row.eventType,
            recordedAt: row.recordedAt,
            valueNumeric: row.valueNumeric,
            valueText: row.valueText,
            unit: row.unit,
            source: row.source,
        )
    }
}

/// One sample as POSTed by the iOS client (HealthKit export, manual entry,
/// Apple Watch sync, etc.). Generic enough to carry sleep stages, recovery
/// scores, steps, heart-rate samples, weight, mindful minutes, and so on.
struct HealthEventInput: Codable {
    let type: String // "sleep_session", "hr_bpm", "steps", "hrv_ms", "weight_kg", ...
    let recordedAt: Date // sample timestamp (start, for intervals)
    let valueNumeric: Double?
    let valueText: String?
    let unit: String? // "minutes", "bpm", "ms", "kg", ...
    let source: String? // "apple_health", "google_fit", "manual", "withings", ...
    let metadata: [String: String]? // free-form (sleep stage, app source, end time, etc.)
}

struct HealthIngestRequest: Codable {
    let events: [HealthEventInput]
}

/// Bulk-inserts HealthEvent rows under the authenticated tenant. Each
/// event must carry either `valueNumeric` or `valueText` (or both — for
/// e.g. sleep where you want both a duration AND a categorical stage).
/// Empty payload is rejected; per-event validation skips malformed rows
/// rather than failing the whole batch.
struct HealthIngestController {
    let fluent: Fluent
    let eventBus: EventBus?
    let logger: Logger
    let maxBatchSize: Int

    init(fluent: Fluent, eventBus: EventBus? = nil, logger: Logger, maxBatchSize: Int = 1000) {
        self.fluent = fluent
        self.eventBus = eventBus
        self.logger = logger
        self.maxBatchSize = maxBatchSize
    }

    /// HER-202 paging knobs. Default 100 / max 200 mirrors what a single
    /// dashboard pane can render without scrollback; iOS pages further as
    /// the user scrolls.
    private static let defaultLimit = 100
    private static let maxLimit = 200

    /// Default read window when neither `from` nor `to` is supplied. Health
    /// dashboards almost always open on "last 7 days"; widen via query
    /// params for long-term review.
    private static let defaultWindowSeconds: TimeInterval = 7 * 86400

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: ingest)
    }

    /// HER-202 — read routes are mounted on a SEPARATE router group in
    /// `App+build.swift` so the ingest-only `EntitlementMiddleware` does
    /// not gate read of own data. Read of own data is always allowed,
    /// even on `lapsed` / `archived` tiers (export-window behaviour).
    func addReadRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
        router.get("daily", use: daily)
    }

    /// HER-118 — per-day aggregation window for sparkline rendering. Sum
    /// for accumulating metrics (`steps`, `active_energy`, `mindful_minutes`),
    /// average for instantaneous metrics. Fills gap-days with
    /// `value: 0, sampleCount: 0` so the response always has exactly `days`
    /// chronological entries — the client renders sparklines without
    /// local bucketing or gap-fill logic.
    @Sendable
    func daily(_ req: Request, ctx: AppRequestContext) async throws -> HealthDailyResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()

        guard let typeRaw = req.uri.queryParameters["type"].map(String.init),
              case let trimmed = typeRaw.trimmingCharacters(in: .whitespaces).lowercased(),
              !trimmed.isEmpty
        else {
            throw HTTPError(.badRequest, message: "type query parameter required")
        }
        let type = trimmed

        let requestedDays = req.uri.queryParameters["days"].flatMap { Int($0) } ?? Self.dailyDefaultDays
        guard requestedDays >= 1, requestedDays <= Self.dailyMaxDays else {
            throw HTTPError(.badRequest, message: "days must be between 1 and \(Self.dailyMaxDays)")
        }

        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let endOfDay = utc.startOfDay(for: Date()).addingTimeInterval(86400)
        let startOfWindow = endOfDay.addingTimeInterval(-Double(requestedDays) * 86400)

        let useSum = Self.sumAggregationTypes.contains(type)

        let db = fluent.db()
        guard let sql = db as? any SQLDatabase else {
            throw HTTPError(.internalServerError, message: "SQL database required for daily aggregation")
        }

        // Aggregation operator switches on a closed Swift-side set; the SQL
        // strings are otherwise identical and never carry user input.
        let rows: [DailyAggregateRow] = if useSum {
            try await sql.raw("""
            SELECT date_trunc('day', recorded_at AT TIME ZONE 'UTC') AS day,
                   SUM(value_numeric) AS value,
                   COUNT(*) AS sample_count
            FROM health_events
            WHERE tenant_id = \(bind: tenantID)
              AND event_type = \(bind: type)
              AND recorded_at >= \(bind: startOfWindow)
              AND recorded_at < \(bind: endOfDay)
              AND value_numeric IS NOT NULL
            GROUP BY day
            ORDER BY day ASC
            """).all(decoding: DailyAggregateRow.self)
        } else {
            try await sql.raw("""
            SELECT date_trunc('day', recorded_at AT TIME ZONE 'UTC') AS day,
                   AVG(value_numeric) AS value,
                   COUNT(*) AS sample_count
            FROM health_events
            WHERE tenant_id = \(bind: tenantID)
              AND event_type = \(bind: type)
              AND recorded_at >= \(bind: startOfWindow)
              AND recorded_at < \(bind: endOfDay)
              AND value_numeric IS NOT NULL
            GROUP BY day
            ORDER BY day ASC
            """).all(decoding: DailyAggregateRow.self)
        }

        var indexed: [Date: HealthDayAggregateDTO] = [:]
        for row in rows {
            indexed[row.day] = HealthDayAggregateDTO(
                date: row.day,
                type: type,
                value: row.value,
                sampleCount: row.sample_count,
            )
        }

        var days: [HealthDayAggregateDTO] = []
        days.reserveCapacity(requestedDays)
        for offset in 0 ..< requestedDays {
            let bucket = startOfWindow.addingTimeInterval(Double(offset) * 86400)
            days.append(indexed[bucket] ?? HealthDayAggregateDTO(
                date: bucket,
                type: type,
                value: 0,
                sampleCount: 0,
            ))
        }

        return HealthDailyResponse(type: type, days: days)
    }

    /// HER-118 — event types whose daily aggregation is a sum rather than
    /// an average. Accumulators: steps, active energy burned, mindful
    /// minutes, and sleep session duration. Everything else (heart rate,
    /// HRV, weight, blood oxygen, etc.) is averaged.
    static let sumAggregationTypes: Set<String> = [
        "steps",
        "active_energy",
        "mindful_minutes",
        "sleep_session",
    ]

    private static let dailyDefaultDays = 7
    private static let dailyMaxDays = 90

    private struct DailyAggregateRow: Decodable {
        let day: Date
        let value: Double
        let sample_count: Int
    }

    @Sendable
    func ingest(_ req: Request, ctx: AppRequestContext) async throws -> HealthIngestResponse {
        let user = try ctx.requireIdentity()
        let body = try await req.decode(as: HealthIngestRequest.self, context: ctx)
        guard !body.events.isEmpty else {
            throw HTTPError(.badRequest, message: "events array required")
        }
        guard body.events.count <= maxBatchSize else {
            throw HTTPError(.contentTooLarge, message: "batch exceeds \(maxBatchSize) events")
        }
        let tenantID = try user.requireID()
        let db = fluent.db()

        var refs: [HealthIngestedRef] = []
        var skipped = 0

        for input in body.events {
            let trimmedType = input.type.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedType.isEmpty,
                  trimmedType.count <= 64,
                  input.valueNumeric != nil || input.valueText != nil
            else {
                skipped += 1
                continue
            }
            let row = HealthEvent(
                tenantID: tenantID,
                eventType: trimmedType.lowercased(),
                valueNumeric: input.valueNumeric,
                valueText: input.valueText,
                unit: input.unit,
                recordedAt: input.recordedAt,
                source: input.source,
                metadata: input.metadata,
            )
            try await row.save(on: db)
            try refs.append(HealthIngestedRef(
                id: row.requireID(),
                type: row.eventType,
                recordedAt: row.recordedAt,
            ))
        }

        logger.info("health ingest tenant=\(tenantID) inserted=\(refs.count) skipped=\(skipped)")

        // HER-171: emit a single aggregate `health_event_synced` event per
        // batch (not per sample — high-frequency HK pushes would otherwise
        // flood the bus and burn the bounded buffer). Payload carries the
        // dominant sample type + count so subscribers can decide whether
        // to dispatch the correlator skill yet.
        if let eventBus, !refs.isEmpty {
            let dominantType = Self.dominantSampleType(refs)
            let event = SkillEvent(
                type: .healthEventSynced,
                tenantID: tenantID,
                payload: [
                    SkillEvent.PayloadKey.healthSampleType: dominantType,
                    SkillEvent.PayloadKey.healthSampleCount: String(refs.count),
                ],
            )
            eventBus.publish(event)
        }

        return HealthIngestResponse(
            inserted: refs.count,
            skipped: skipped,
            events: refs,
        )
    }

    /// HER-202 — paginated list of `HealthEvent` rows for the authenticated
    /// tenant. Query params:
    ///
    /// * `type` — optional case-insensitive `event_type` filter
    /// * `from` / `to` — ISO-8601 instants; default last 7 days
    /// * `limit` — 1..200, default 100
    /// * `offset` — 0..N, default 0
    ///
    /// Ordered `recorded_at` DESC so the freshest sample is index 0. Reuses
    /// `HealthEvent.query(on: db, tenantID:)` already used by
    /// `HealthCorrelationService.collectEvents(...)`.
    @Sendable
    func list(_ req: Request, ctx: AppRequestContext) async throws -> HealthListResponse {
        let user = try ctx.requireIdentity()
        let tenantID = try user.requireID()
        let db = fluent.db()

        let rawLimit = req.uri.queryParameters["limit"].flatMap { Int($0) } ?? Self.defaultLimit
        let limit = Self.clamp(rawLimit, min: 1, max: Self.maxLimit)
        let offset = max(0, req.uri.queryParameters["offset"].flatMap { Int($0) } ?? 0)
        let type = req.uri.queryParameters["type"]
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }

        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoLegacy = ISO8601DateFormatter()
        isoLegacy.formatOptions = [.withInternetDateTime]
        func parseDate(_ raw: String) -> Date? {
            iso.date(from: raw) ?? isoLegacy.date(from: raw)
        }
        let from = req.uri.queryParameters["from"]
            .map { String($0) }
            .flatMap(parseDate)
            ?? now.addingTimeInterval(-Self.defaultWindowSeconds)
        let to = req.uri.queryParameters["to"]
            .map { String($0) }
            .flatMap(parseDate)
            ?? now

        var query = HealthEvent.query(on: db, tenantID: tenantID)
            .filter(\.$recordedAt >= from)
            .filter(\.$recordedAt < to)
            .sort(\.$recordedAt, .descending)
        if let type {
            query = query.filter(\.$eventType == type)
        }
        let rows = try await query.range(offset ..< (offset + limit)).all()

        return HealthListResponse(
            events: rows.map(HealthEventDTO.fromHealthEvent),
            limit: limit,
            offset: offset,
        )
    }

    private static func clamp(_ value: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, value))
    }

    /// Most-common event type in the batch. Used purely for the
    /// `health_event_synced` payload hint so subscribers can short-circuit
    /// without inspecting the database.
    private static func dominantSampleType(_ refs: [HealthIngestedRef]) -> String {
        var counts: [String: Int] = [:]
        for ref in refs {
            counts[ref.type, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key ?? "unknown"
    }
}
