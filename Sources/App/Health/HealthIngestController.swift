import FluentKit
import Foundation
import Hummingbird
import HummingbirdFluent
import Logging

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

struct HealthIngestedRef: Codable {
    let id: UUID
    let type: String
    let recordedAt: Date
}

struct HealthIngestResponse: Codable, ResponseEncodable {
    let inserted: Int
    let skipped: Int
    let events: [HealthIngestedRef]
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

    func addRoutes(to router: RouterGroup<AppRequestContext>) {
        router.post("", use: ingest)
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
            await eventBus.publish(event)
        }

        return HealthIngestResponse(
            inserted: refs.count,
            skipped: skipped,
            events: refs,
        )
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
