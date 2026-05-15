import Foundation
import LuminaVaultShared
import NIOCore

/// HER-203 — uniform interface every upstream STT (speech-to-text)
/// provider implements. v1 ships with `GroqWhisperAdapter`; OpenAI /
/// Replicate / on-device Whisper drop in via additional conformances.
///
/// Implementations:
/// - MUST translate the provider's native audio-transcription wire shape
///   to a normalized `TranscribeUpstreamResult`.
/// - MUST throw `TranscribeProviderError` (never bare `URLError` / decode
///   errors) so the service layer can map to HTTP status cleanly.
/// - SHOULD NOT retry internally — the service layer owns retry policy
///   when (or if) we add failover across providers later.
protocol TranscribeProviderAdapter: Sendable {
    var kind: TranscribeProviderKind { get }

    /// Send a single transcription request. `audio` carries the raw bytes
    /// of an `audio/{m4a,wav,mpeg,webm}` file; `mime` is the verbatim
    /// `Content-Type` the controller validated upstream.
    func transcribe(audio: ByteBuffer, mime: String) async throws -> TranscribeUpstreamResult
}

/// Stable identifier per provider. Map 1:1 to the `transcribe.provider`
/// env knob — `transcribe.provider=groq` selects `.groq`.
enum TranscribeProviderKind: String, Sendable, CaseIterable {
    case groq
    case openai
    case replicate
    case stub
}

/// Normalized result returned from any `TranscribeProviderAdapter`. The
/// service layer converts this into the wire `TranscribeResponse`.
struct TranscribeUpstreamResult: Sendable {
    let text: String
    let language: String
    /// Confidence in `[0,1]`. Providers that don't expose a single number
    /// (Groq returns per-segment `avg_logprob`) should map their native
    /// signal to this range; see `GroqWhisperAdapter` for the convention.
    let confidence: Double
    /// Duration of the transcribed audio in seconds. Used by
    /// `UsageMeterService` to compute the mtok-equivalent billing unit.
    let durationSeconds: Double
    let segments: [TranscribeSegment]?
}

/// Typed errors thrown by adapters. The controller maps these to HTTP
/// status codes; the service layer can also use `.isRecoverable` to
/// decide whether to fail over (currently no-op — single provider).
enum TranscribeProviderError: Error {
    case transient(provider: TranscribeProviderKind, status: Int, body: String?)
    case permanent(provider: TranscribeProviderKind, status: Int, body: String?)
    case network(provider: TranscribeProviderKind, underlying: any Error)
    case decode(provider: TranscribeProviderKind, underlying: any Error)

    var isRecoverable: Bool {
        switch self {
        case .transient, .network: true
        case .permanent, .decode: false
        }
    }
}
