import Foundation
import LuminaVaultShared
import NIOCore

/// HER-203 — uniform interface every upstream STT (speech-to-text)
/// provider implements. Ships with `OpenAICompatibleTranscribeAdapter`,
/// which covers the cluster's own whisper service and every hosted provider
/// serving the same wire format.
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

    /// Send a single transcription request. `audio` carries the raw bytes of
    /// an audio file whose type is in `TranscribeController.acceptedMimes`;
    /// `mime` is the verbatim `Content-Type` the controller validated upstream.
    func transcribe(audio: ByteBuffer, mime: String) async throws -> TranscribeUpstreamResult
}

/// Stable identifier per provider. Maps 1:1 to the `transcribe.provider` env
/// knob — `transcribe.provider=openai_compatible` selects `.openaiCompatible`.
///
/// There is deliberately one real case. Every endpoint worth talking to serves
/// the OpenAI `/audio/transcriptions` shape, so which one you reach is a base
/// URL rather than a code path — that is what keeps moving between the
/// in-cluster service and a hosted one a configuration change.
enum TranscribeProviderKind: String, CaseIterable {
    case openaiCompatible = "openai_compatible"
    case stub

    /// Segment used in `transcribe.provider.<segment>.*` config keys.
    ///
    /// Deliberately *not* the raw value. The selector reads
    /// `TRANSCRIBE_PROVIDER=openai_compatible`, but its settings live under
    /// `TRANSCRIBE_PROVIDER_OPENAI_*`. Deriving the segment from the raw value
    /// would silently rename them to `TRANSCRIBE_PROVIDER_OPENAI_COMPATIBLE_*`
    /// and read nothing.
    ///
    /// Note the *suffix* spelling, which an earlier version of this comment
    /// got wrong: `ConfigReader` encodes `…openai.baseURL` as
    /// `TRANSCRIBE_PROVIDER_OPENAI_BASE_URL`, inserting `_` where a lowercase
    /// letter meets an uppercase one. The flattened `_BASEURL` / `_APIKEY`
    /// spellings load nothing here — unlike the chat-routing registry, this
    /// path carries no legacy aliases. `TranscribeProviderConfigTests` pins
    /// both the spellings that work and the ones that silently do not.
    var configKey: String {
        switch self {
        case .openaiCompatible: "openai"
        case .stub: "stub"
        }
    }
}

/// Normalized result returned from any `TranscribeProviderAdapter`. The
/// service layer converts this into the wire `TranscribeResponse`.
struct TranscribeUpstreamResult: Sendable {
    let text: String
    let language: String
    /// Confidence in `[0,1]`. Providers that don't expose a single number
    /// (Whisper-family endpoints return per-segment `avg_logprob`) should map
    /// their native signal to this range; see
    /// `OpenAICompatibleTranscribeAdapter` for the convention. Endpoints that
    /// return only `{"text": ...}` report `0` — unknown, not zero-confidence.
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
