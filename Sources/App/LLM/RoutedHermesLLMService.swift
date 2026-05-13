import Foundation
import Hummingbird
import Logging
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
    private let encoder = JSONEncoder()

    let successCounter = Counter(label: "luminavault.llm.chat.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.failure")
    let durationTimer = Timer(label: "luminavault.llm.chat.duration")

    init(
        transport: any HermesChatTransport,
        defaultModel: String,
        logger: Logger,
    ) {
        self.transport = transport
        self.defaultModel = defaultModel
        self.logger = logger
    }

    func chat(profileUsername: String, request: ChatRequest) async throws -> ChatResponse {
        let started = DispatchTime.now().uptimeNanoseconds

        let payload = ChatCompletionPayload(
            model: request.model ?? defaultModel,
            messages: request.messages.map { $0.toOutbound() },
            temperature: request.temperature,
            stream: false,
            tools: request.tools?.map { $0.toOutbound() },
            tool_choice: request.tool_choice,
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
                    profileUsername: profileUsername,
                )
                let decoded = try JSONDecoder().decode(HermesUpstreamResponse.self, from: response)
                guard let assistant = decoded.choices.first?.message else {
                    failureCounter.increment()
                    throw HTTPError(.badGateway, message: "llm upstream returned no choices")
                }
                successCounter.increment()
                durationTimer.recordNanoseconds(
                    Int64(DispatchTime.now().uptimeNanoseconds - started)
                )
                logger.info("llm reply ready model=\(decoded.model) profile=\(profileUsername)")
                return ChatResponse(
                    id: decoded.id,
                    model: decoded.model,
                    message: assistant,
                    raw: decoded)
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
