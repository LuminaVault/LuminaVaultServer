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
struct TranscribeService: Sendable {
    let registry: TranscribeProviderRegistry
    let usageMeter: UsageMeterService?
    let logger: Logger

    func transcribe(audio: ByteBuffer, mime: String, tenantID: UUID) async throws -> TranscribeResponse {
        guard let adapter = await registry.active() else {
            logger.error("no active transcribe provider — check transcribe.provider env knob")
            throw HTTPError(.serviceUnavailable, message: "transcribe provider not configured")
        }

        let result: TranscribeUpstreamResult
        do {
            result = try await adapter.transcribe(audio: audio, mime: mime)
        } catch let providerError as TranscribeProviderError {
            logger.error("transcribe provider error: \(providerError)")
            switch providerError {
            case .permanent:
                throw HTTPError(.badGateway, message: "transcribe upstream rejected request")
            case .transient, .network, .decode:
                throw HTTPError(.badGateway, message: "transcribe upstream unavailable")
            }
        }

        if let usageMeter {
            let kind = await registry.activeKindResolved()
            let perSecond = await registry.mtokPerSecond(for: kind)
            let tokensIn = Int((result.durationSeconds * perSecond * 1_000_000).rounded())
            if tokensIn > 0 {
                let meter = usageMeter
                let modelToRecord = "transcribe:\(kind.rawValue)"
                Task { await meter.record(tenantID: tenantID, model: modelToRecord, tokensIn: tokensIn, tokensOut: 0) }
            }
        }

        return TranscribeResponse(
            id: UUID().uuidString,
            text: result.text,
            language: result.language,
            confidence: result.confidence,
            durationSeconds: result.durationSeconds,
            segments: result.segments,
        )
    }
}
