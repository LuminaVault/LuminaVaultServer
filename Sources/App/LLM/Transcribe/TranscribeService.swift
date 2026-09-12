import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import NIOCore

/// HER-203 — coordinates the active STT adapter, the usage meter, and the
/// wire `TranscribeResponse` mapping. Sits between `TranscribeController`
/// (HTTP boundary) and `TranscribeProviderAdapter` (upstream Whisper).
///
/// Why a separate service (vs inlining into the controller):
/// - keeps the controller focused on HTTP concerns (status mapping,
///   body-size enforcement, auth context),
/// - gives tests a single seam to inject a stub adapter without booting
///   the full router,
/// - leaves room for a future failover loop across providers without
///   touching the controller signature.
struct TranscribeService {
    let registry: TranscribeProviderRegistry
    let usageMeter: UsageMeterService?
    /// Per-request metering. Optional so a deployment without a database
    /// (and every unit test that does not care) still transcribes.
    let voiceUsage: (any VoiceUsageRecorder)?
    let logger: Logger

    func transcribe(
        audio: ByteBuffer,
        mime: String,
        tenantID: UUID,
        channel: String? = nil
    ) async throws -> TranscribeResponse {
        let kind = await registry.activeKindResolved()
        let model = await registry.model(for: kind) ?? ""
        let attempt = Attempt(
            tenantID: tenantID,
            occurredAt: Date(),
            startedAt: ContinuousClock.now,
            channel: VoiceChannel.sanitized(channel),
            kind: kind,
            model: model,
            audioBytes: Int64(audio.readableBytes)
        )

        guard let adapter = await registry.active() else {
            logger.error("no active transcribe provider — check transcribe.provider env knob")
            await meter(attempt, outcome: .noProvider)
            throw HTTPError(.serviceUnavailable, message: "transcribe provider not configured")
        }

        let result: TranscribeUpstreamResult
        do {
            result = try await adapter.transcribe(audio: audio, mime: mime)
        } catch let providerError as TranscribeProviderError {
            logger.error("transcribe provider error: \(providerError)")
            await meter(attempt, outcome: VoiceUsageOutcome(providerError: providerError))
            switch providerError {
            case .permanent:
                throw HTTPError(.badGateway, message: "transcribe upstream rejected request")
            case .transient, .network, .decode:
                throw HTTPError(.badGateway, message: "transcribe upstream unavailable")
            }
        }

        if let usageMeter {
            let perSecond = await registry.mtokPerSecond(for: kind)
            let tokensIn = Int((result.durationSeconds * perSecond * 1_000_000).rounded())
            if tokensIn > 0 {
                let meter = usageMeter
                let modelToRecord = "transcribe:\(kind.rawValue)"
                Task { await meter.record(tenantID: tenantID, model: modelToRecord, tokensIn: tokensIn, tokensOut: 0) }
            }
        }

        let response = TranscribeResponse(
            id: UUID().uuidString,
            text: result.text,
            language: result.language,
            confidence: result.confidence,
            durationSeconds: result.durationSeconds,
            segments: result.segments
        )

        await meter(
            attempt,
            outcome: .ok,
            durationSeconds: result.durationSeconds,
            language: result.language,
            idempotencyKey: response.id
        )

        return response
    }

    // MARK: - Metering

    /// Everything about a transcription attempt that is fixed before the
    /// upstream call, gathered once.
    ///
    /// A struct rather than a long parameter list: the three metering call
    /// sites differ only in how the attempt *ended*, so passing the same
    /// seven values through each of them was both noise and an easy place to
    /// transpose two arguments of the same type.
    private struct Attempt {
        let tenantID: UUID
        let occurredAt: Date
        let startedAt: ContinuousClock.Instant
        let channel: String
        let kind: TranscribeProviderKind
        let model: String
        let audioBytes: Int64
    }

    /// Record one attempt to the per-request ledger and to the live metrics.
    ///
    /// Awaited rather than fired into a detached `Task`: a per-request row is
    /// worth an insert's latency on a path that already waited on an upstream
    /// HTTP call, and a detached task can be dropped at shutdown — exactly
    /// when a failure spike is most worth having recorded. (The repo rule
    /// against fire-and-forget `Task` says the same thing.) The store swallows
    /// its own errors, so this cannot fail the request.
    ///
    /// `durationSeconds` defaults to zero because a failed attempt has no
    /// audio duration to bill — only a successful one passes it.
    private func meter(
        _ attempt: Attempt,
        outcome: VoiceUsageOutcome,
        durationSeconds: Double = 0,
        language: String? = nil,
        idempotencyKey: String? = nil
    ) async {
        let rateCard = await registry.rateCard(for: attempt.kind)

        let event = VoiceUsageEvent(
            tenantID: attempt.tenantID,
            occurredAt: attempt.occurredAt,
            channel: attempt.channel,
            surface: VoiceUsageEvent.voiceNoteSurface,
            provider: attempt.kind.rawValue,
            model: attempt.model,
            outcome: outcome,
            durationMilliseconds: Self.milliseconds(fromSeconds: durationSeconds),
            latencyMilliseconds: Self.milliseconds(since: attempt.startedAt),
            audioBytes: attempt.audioBytes,
            language: language,
            // Real spend. The in-cluster whisper service bills nothing per
            // request, and a hosted provider's true invoice is reconciled
            // through `cost_ledger`, not guessed here.
            usdMicros: 0,
            imputedUsdMicros: rateCard.imputedUsdMicros(durationSeconds: durationSeconds),
            idempotencyKey: idempotencyKey ?? UUID().uuidString
        )

        VoiceMetrics.recordTranscribe(event)
        await voiceUsage?.record(event)
    }

    /// Milliseconds, floored at zero. Sub-second voice notes must not round
    /// to nothing — a 900ms clip that meters as 0 is a clip that bills as
    /// free.
    static func milliseconds(fromSeconds seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 1000).rounded())
    }

    /// Wall-clock milliseconds since `start`, measured on `ContinuousClock`
    /// so a wall-clock adjustment mid-request cannot produce a negative
    /// latency or a nonsense spike.
    static func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = ContinuousClock.now - start
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        return max(0, elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / attosecondsPerMillisecond)
    }
}
