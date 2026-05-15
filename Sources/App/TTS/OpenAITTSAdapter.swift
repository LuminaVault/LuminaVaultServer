import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-204 — OpenAI `POST /v1/audio/speech` adapter. URLSession-based,
/// same shape as `HermesGatewayAdapter` so the routed dispatcher and the
/// `ProviderError` classification rules work uniformly across LLM + TTS.
///
/// Auth: bearer token from `llm.provider.openai.apiKey` (already loaded
/// at boot by `ProviderRegistry.loadConfigs`). Base URL defaults to the
/// public OpenAI endpoint but is overridable via
/// `llm.provider.openai.baseURL` for testing / proxying.
///
/// Voice mapping: `"lumina"` → `"alloy"` for MVP. Until a real cloned
/// Lumina voice ships behind an ElevenLabs/Cartesia adapter, every
/// request to LuminaVault's `"lumina"` voice is served by the stock
/// OpenAI `alloy` voice.
struct OpenAITTSAdapter: TTSProviderAdapter {
    let kind: ProviderKind = .openai
    let apiKey: String
    let baseURL: URL
    let defaultModel: String
    let session: URLSession
    let logger: Logger

    init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        defaultModel: String = "tts-1",
        session: URLSession = .shared,
        logger: Logger,
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.session = session
        self.logger = logger
    }

    func synthesize(text: String, voice: String, modelID: String?) async throws -> TTSSynthesisResponse {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("audio")
            .appendingPathComponent("speech")

        let providerVoice = Self.mapVoice(voice)
        let model = modelID ?? defaultModel

        let body: [String: Any] = [
            "model": model,
            "input": text,
            "voice": providerVoice,
            "response_format": "mp3",
        ]
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw ProviderError.network(provider: kind, underlying: error)
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw ProviderError.network(provider: kind, underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.transient(provider: kind, status: 0, body: nil)
        }
        let status = http.statusCode
        if (200 ..< 300).contains(status) {
            return TTSSynthesisResponse(
                audioData: data,
                contentType: "audio/mpeg",
                charactersBilled: text.count,
            )
        }
        let preview = String(data: data.prefix(512), encoding: .utf8)
        if status == 429 || (500 ..< 600).contains(status) {
            logger.error("openai tts transient \(status): \(preview ?? "<binary>")")
            throw ProviderError.transient(provider: kind, status: status, body: preview)
        }
        logger.error("openai tts permanent \(status): \(preview ?? "<binary>")")
        throw ProviderError.permanent(provider: kind, status: status, body: preview)
    }

    /// LuminaVault voice name → OpenAI voice id. Unknown LuminaVault
    /// names fall through to `alloy` rather than 4xx so the contract
    /// stays additive: the iOS app can ship a new voice option before
    /// the server-side mapping catches up.
    private static func mapVoice(_ luminaVoice: String) -> String {
        switch luminaVoice.lowercased() {
        case "lumina", "alloy":
            "alloy"
        case "echo":
            "echo"
        case "fable":
            "fable"
        case "onyx":
            "onyx"
        case "nova":
            "nova"
        case "shimmer":
            "shimmer"
        default:
            "alloy"
        }
    }
}
