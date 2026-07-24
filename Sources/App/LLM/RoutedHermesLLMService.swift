import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import Tracing

/// HER-200 — `HermesLLMService` implementation backed by
/// `RoutedLLMTransport`. Unlike `DefaultHermesLLMService` which hits
/// the Hermes gateway directly, this routes through the provider
/// registry + model router, enabling Gemini routing, failover, and
/// cost-aware provider selection for the user-facing `/v1/llm/chat`
/// endpoint.
struct RoutedHermesLLMService: HermesLLMService {
    private let transport: any HermesChatTransport
    private let defaultModel: String
    private let logger: Logger
    /// Resolves the tenant's brain mode so managed responses never carry the
    /// concrete upstream model id (`ModelDisclosurePolicy`). Optional so
    /// existing constructions/tests keep working; nil = treat as managed.
    private let preferences: UserLLMPreferenceRepository?
    private let encoder = JSONEncoder()

    let successCounter = Counter(label: "luminavault.llm.chat.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.failure")
    let durationTimer = Timer(label: "luminavault.llm.chat.duration")

    init(
        transport: any HermesChatTransport,
        defaultModel: String,
        logger: Logger,
        preferences: UserLLMPreferenceRepository? = nil
    ) {
        self.transport = transport
        self.defaultModel = defaultModel
        self.logger = logger
        self.preferences = preferences
    }

    func chat(sessionKey: String, sessionID: String?, request: ChatRequest) async throws -> ChatResponse {
        let started = DispatchTime.now().uptimeNanoseconds

        let payload = ChatCompletionPayload(
            model: request.model ?? defaultModel,
            messages: request.messages.map { $0.toOutbound() },
            temperature: request.temperature,
            stream: false,
            tools: request.tools?.map { $0.toOutbound() },
            tool_choice: request.tool_choice
        )

        let data: Data
        do {
            data = try encoder.encode(payload)
        } catch {
            logger.error("failed to encode chat payload: \(error)")
            failureCounter.increment()
            throw HTTPError(.internalServerError)
        }

        return try await withSpan("hermes.chat", ofKind: .client) { _ in
            do {
                let response = try await transport.chatCompletions(
                    payload: data,
                    sessionKey: sessionKey,
                    sessionID: sessionID
                )
                let decoded = try JSONDecoder().decode(HermesUpstreamResponse.self, from: response)
                guard let assistant = decoded.choices.first?.message else {
                    failureCounter.increment()
                    throw HTTPError(.badGateway, message: "llm upstream returned no choices")
                }
                // HER-XX — sanitize raw bash/Python stderr from the
                // assistant content + capture structured tool-failure
                // events for telemetry. Mirrors the legacy
                // `DefaultHermesLLMService` path so behaviour is
                // identical regardless of which transport routed the
                // request.
                let toolErrors = HermesToolErrorClassifier.classify(content: assistant.content)
                HermesToolErrorClassifier.observe(
                    errors: toolErrors,
                    model: decoded.model,
                    profile: sessionKey,
                    logger: logger
                )
                let sanitized = HermesToolErrorClassifier.sanitize(message: assistant)
                successCounter.increment()
                durationTimer.recordNanoseconds(
                    Int64(DispatchTime.now().uptimeNanoseconds - started)
                )
                logger.info("llm reply ready model=\(decoded.model) sessionKey=\(sessionKey)")
                // Managed tenants never see the concrete model id — scrub the
                // wire response (server logs above keep the real one).
                if await disclosure(sessionKey: sessionKey) == .hidden {
                    let scrubbedRaw = HermesUpstreamResponse(
                        id: decoded.id,
                        object: decoded.object,
                        created: decoded.created,
                        model: ModelDisclosurePolicy.genericModelID,
                        choices: decoded.choices,
                        usage: decoded.usage
                    )
                    return ChatResponse(
                        id: decoded.id,
                        model: ModelDisclosurePolicy.genericModelID,
                        message: sanitized,
                        raw: scrubbedRaw
                    )
                }
                return ChatResponse(
                    id: decoded.id,
                    model: decoded.model,
                    message: sanitized,
                    raw: decoded
                )
            } catch let responseError as any HTTPResponseError {
                failureCounter.increment()
                throw responseError
            } catch let httpErr as HTTPError {
                failureCounter.increment()
                throw httpErr
            } catch {
                failureCounter.increment()
                logger.error("llm chat failed: \(error)")
                throw HTTPError(.badGateway, message: "llm upstream error: \(error)")
            }
        }
    }
}

extension RoutedHermesLLMService {
    /// `.visible` only for a tenant explicitly in BYOK mode; anything else
    /// (no repo wired, unparsable session key, no row) stays `.hidden`.
    private func disclosure(sessionKey: String) async -> ModelDisclosure {
        guard let preferences,
              let tenantID = UUID(uuidString: sessionKey),
              let pref = try? await preferences.get(tenantID: tenantID),
              pref.mode == .byok
        else { return .hidden }
        return .visible
    }
}

/// Encodable wrapper for the OpenAI chat-completions POST body.
private struct ChatCompletionPayload: Encodable {
    let model: String
    let messages: [OutboundMessage]
    let temperature: Double?
    let stream: Bool
    let tools: [OutboundTool]?
    let tool_choice: AnyJSONValue?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream, tools
        case tool_choice
    }
}
