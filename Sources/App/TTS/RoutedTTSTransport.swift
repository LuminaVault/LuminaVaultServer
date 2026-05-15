import Foundation
import Hummingbird
import Logging

/// HER-204 — single-adapter dispatcher for TTS synthesis. Parallel to
/// `RoutedLLMTransport` but trimmed to the MVP shape: one provider
/// (OpenAI) wired in, no failover loop. When a second adapter lands
/// (ElevenLabs / Cartesia / Google), this struct grows a candidate
/// list + the same `.transient` / `.network` failover walk used by
/// `RoutedLLMTransport.chatCompletionsWithMetadata`.
///
/// Hot-path side-effect: a successful synthesis fires a detached
/// `UsageMeterService.record(charactersOut:)` task so billing never
/// blocks audio delivery. Same fail-soft contract as the token
/// recorder — metering loss is acceptable; a stuck audio response
/// is not.
struct RoutedTTSTransport: Sendable {
    let adapter: any TTSProviderAdapter
    let defaultModel: String
    let logger: Logger
    let usageMeter: UsageMeterService?

    init(
        adapter: any TTSProviderAdapter,
        defaultModel: String,
        logger: Logger,
        usageMeter: UsageMeterService? = nil,
    ) {
        self.adapter = adapter
        self.defaultModel = defaultModel
        self.logger = logger
        self.usageMeter = usageMeter
    }

    /// Synthesise `text` into audio using the configured adapter.
    /// `userID` is passed for usage-meter recording; pass `nil` to skip
    /// metering (test paths). Provider errors are mapped to
    /// `HTTPError(.badGateway)` so the controller doesn't need to know
    /// `ProviderError` internals.
    func synthesize(
        text: String,
        voice: String,
        userID: UUID?,
    ) async throws -> TTSSynthesisResponse {
        do {
            let result = try await adapter.synthesize(text: text, voice: voice, modelID: defaultModel)
            if let usageMeter, let userID, result.charactersBilled > 0 {
                let meter = usageMeter
                let model = defaultModel
                let chars = result.charactersBilled
                Task { await meter.record(tenantID: userID, model: model, charactersOut: chars) }
            }
            return result
        } catch let providerError as ProviderError {
            logger.error("tts upstream failed", metadata: [
                "provider": .string(providerError.provider.rawValue),
                "error": .string("\(providerError)"),
            ])
            if providerError.isRecoverable {
                throw HTTPError(.badGateway, message: "tts upstream unavailable")
            }
            throw HTTPError(.badGateway, message: "tts upstream rejected request (\(providerError.provider.rawValue))")
        }
    }
}
