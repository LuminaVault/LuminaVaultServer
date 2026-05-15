import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging
import LuminaVaultShared

// MARK: - Server-side conformances

extension HealthIngestResponse: ResponseEncodable {}
extension HealthEventDTO: ResponseEncodable {}
extension HealthListResponse: ResponseEncodable {}

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
            metadata: row.metadata,
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
    private static let defaultWindowSeconds: TimeInterval = 7 * 86_400

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: ingest)
    }

    /// HER-202 — read routes are mounted on a SEPARATE router group in
    /// `App+build.swift` so the ingest-only `EntitlementMiddleware` does
    /// not gate read of own data. Read of own data is always allowed,
    /// even on `lapsed` / `archived` tiers (export-window behaviour).
    func addReadRoutes(to router: RouterGroup<AppRequestContext>) {
        router.get("", use: list)
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
