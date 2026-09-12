import FluentKit
import Foundation
import HummingbirdFluent
import Logging
import SQLKit

/// Writes one `usage_events` row per transcription attempt.
///
/// Why a per-request row when `usage_meter` already aggregates by day:
/// `usage_meter` answers "how many units did this tenant burn", which is what
/// a cap needs. It cannot answer "what is our Telegram voice failure rate",
/// "how long is the median voice note", or "what would this have cost
/// hosted" — those need the individual attempts, with their outcome and
/// dimensions intact. Both are kept; they are different questions.
///
/// Errors are logged and swallowed. A metering blip must cost a row, never a
/// user's voice note.
struct VoiceUsageEventStore: VoiceUsageRecorder {
    let fluent: Fluent
    let logger: Logger

    /// `metric` value for an inbound transcription. Matches the CHECK
    /// constraint widened in `M126_AddVoiceUsageMetrics`.
    static let metric = "voice_transcribe"

    /// The JSONB payload. A concrete `Codable` type rather than a dictionary
    /// so the key names are checked at compile time — dashboard queries read
    /// these by name, and a typo would produce rows that look fine and
    /// aggregate to nothing.
    private struct Metadata: Encodable {
        let channel: String
        let surface: String
        let provider: String
        let model: String
        let outcome: String
        let latencyMs: Int64
        let audioBytes: Int64
        let language: String?
        let usdMicros: Int64
        let imputedUsdMicros: Int64

        init(event: VoiceUsageEvent) {
            channel = event.channel
            surface = event.surface
            provider = event.provider
            model = event.model
            outcome = event.outcome.rawValue
            latencyMs = event.latencyMilliseconds
            audioBytes = event.audioBytes
            language = event.language
            usdMicros = event.usdMicros
            imputedUsdMicros = event.imputedUsdMicros
        }
    }

    func record(_ event: VoiceUsageEvent) async {
        guard let sql = fluent.db() as? any SQLDatabase else {
            logger.warning("usage_events requires SQL driver, skipping voice record")
            return
        }

        let metadataJSON: String
        do {
            let data = try JSONEncoder().encode(Metadata(event: event))
            metadataJSON = String(decoding: data, as: UTF8.self)
        } catch {
            // Serialisation cannot realistically fail for this shape, but an
            // empty object keeps the row — the amount and the metric name are
            // the load-bearing parts.
            logger.error("voice usage metadata encode failed", metadata: [
                "error": .string("\(error)"),
            ])
            metadataJSON = "{}"
        }

        do {
            try await sql.raw("""
            INSERT INTO usage_events (tenant_id, occurred_at, metric, amount, source, idempotency_key, metadata)
            VALUES (\(bind: event.tenantID), \(bind: event.occurredAt), \(bind: Self.metric),
                    \(bind: event.durationMilliseconds), \(bind: event.channel),
                    \(bind: event.idempotencyKey), \(bind: metadataJSON)::jsonb)
            ON CONFLICT (tenant_id, idempotency_key) WHERE idempotency_key IS NOT NULL
            DO NOTHING
            """).run()
        } catch {
            logger.error("usage_events voice record failed", metadata: [
                "tenant_id": .string(event.tenantID.uuidString),
                "outcome": .string(event.outcome.rawValue),
                "error": .string("\(error)"),
            ])
        }
    }
}
