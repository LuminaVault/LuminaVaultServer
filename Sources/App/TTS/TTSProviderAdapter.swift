import Foundation

/// HER-204 — uniform interface every upstream TTS provider implements.
/// Parallel to `ProviderAdapter` for chat. MVP has a single
/// `OpenAITTSAdapter` impl; ElevenLabs/Cartesia/Google land as follow-ups.
///
/// Implementations:
/// - MUST translate the OpenAI `/v1/audio/speech` wire shape to / from
///   the provider's native format. Callers hand in already-validated
///   `text` + `voice` (caller enforces the 4 KB UTF-8 cap upstream).
/// - MUST throw `ProviderError` (never bare `URLError` etc.) so the
///   dispatcher can classify failover when a second adapter lands.
/// - SHOULD NOT retry internally — the dispatcher owns retry / failover.
protocol TTSProviderAdapter: Sendable {
    var kind: ProviderKind { get }

    /// Synthesise `text` into audio. `voice` is the LuminaVault-side voice
    /// name (e.g. "lumina"); each adapter maps it to its provider-native
    /// voice id. `modelID` is the routed model (nil → adapter default).
    func synthesize(text: String, voice: String, modelID: String?) async throws -> TTSSynthesisResponse
}

/// HER-204 — synthesis result returned by every TTS adapter. `audioData`
/// is the full encoded clip (no streaming for MVP). `contentType` is the
/// HTTP `Content-Type` we'll set on the response back to the client.
/// `charactersBilled` is what `UsageMeterService.record(charactersOut:)`
/// will record — typically `text.count` but adapters MAY override (e.g.
/// some providers normalise / strip SSML before counting).
struct TTSSynthesisResponse: Sendable {
    let audioData: Data
    let contentType: String
    let charactersBilled: Int

    init(audioData: Data, contentType: String, charactersBilled: Int) {
        self.audioData = audioData
        self.contentType = contentType
        self.charactersBilled = charactersBilled
    }
}
