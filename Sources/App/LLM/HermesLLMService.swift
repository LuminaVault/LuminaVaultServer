import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import Tracing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

protocol HermesLLMService: Sendable {
    /// HER-183 — `sessionKey` is the tenant UUID string (sent as
    /// `X-Hermes-Session-Key`). `sessionID` is optional conversation
    /// continuity (`X-Hermes-Session-Id`); nil for one-shot calls.
    func chat(sessionKey: String, sessionID: String?, request: ChatRequest) async throws -> ChatResponse
}

/// Outbound request body for the Hermes OpenAI-compatible gateway.
private struct HermesUpstreamRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
    }
}

struct DefaultHermesLLMService: HermesLLMService {
    let baseURL: URL
    let session: URLSession
    let defaultModel: String
    let logger: Logger
    /// HER-254 — Bearer key for the central Hermes gateway. Empty skips the header.
    let apiKey: String
    let successCounter = Counter(label: "luminavault.llm.chat.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.failure")
    let durationTimer = Timer(label: "luminavault.llm.chat.duration")

    init(baseURL: URL, session: URLSession, defaultModel: String, logger: Logger, apiKey: String = "") {
        self.baseURL = baseURL
        self.session = session
        self.defaultModel = defaultModel
        self.logger = logger
        self.apiKey = apiKey
    }

    func chat(sessionKey: String, sessionID: String?, request: ChatRequest) async throws -> ChatResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        return try await withSpan("hermes.chat", ofKind: .client) { _ in
            let url = baseURL.appendingPathComponent("v1").appendingPathComponent("chat").appendingPathComponent("completions")
            var urlReq = URLRequest(url: url)
            urlReq.httpMethod = "POST"
            urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // HER-183 — per-tenant memory scoping on the Hermes gateway.
            urlReq.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")
            if let sessionID, !sessionID.isEmpty {
                urlReq.setValue(sessionID, forHTTPHeaderField: "X-Hermes-Session-Id")
            }
            if !apiKey.isEmpty {
                urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let payload = HermesUpstreamRequest(
                model: request.model ?? defaultModel,
                messages: request.messages,
                temperature: request.temperature,
                stream: false
            )
            urlReq.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: urlReq)
            guard let http = response as? HTTPURLResponse else {
                failureCounter.increment()
                throw HTTPError(.badGateway, message: "hermes upstream returned no http response")
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
                logger.error("hermes upstream \(http.statusCode): \(preview)")
                failureCounter.increment()
                throw HTTPError(.badGateway, message: "hermes upstream error (\(http.statusCode))")
            }

            let decoder = JSONDecoder()
            let raw: HermesUpstreamResponse
            do {
                raw = try decoder.decode(HermesUpstreamResponse.self, from: data)
            } catch {
                let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
                logger.error("hermes decode failed: \(error). body=\(preview)")
                failureCounter.increment()
                throw HTTPError(.badGateway, message: "hermes upstream returned malformed body")
            }
            guard let assistant = raw.choices.first?.message else {
                failureCounter.increment()
                throw HTTPError(.badGateway, message: "hermes upstream returned no choices")
            }
            // HER-XX — strip raw bash/Python stderr leaks from the
            // assistant content before they ever hit the wire, and
            // emit a structured log + metric per failed tool so the
            // failure mode is observable without leaking implementation
            // details to end users.
            let toolErrors = HermesToolErrorClassifier.classify(content: assistant.content)
            HermesToolErrorClassifier.observe(
                errors: toolErrors,
                model: raw.model,
                profile: sessionKey,
                logger: logger
            )
            let sanitized = HermesToolErrorClassifier.sanitize(message: assistant)
            successCounter.increment()
            durationTimer.recordNanoseconds(Int64(DispatchTime.now().uptimeNanoseconds - started))
            logger.info("hermes reply ready model=\(raw.model) sessionKey=\(sessionKey)")
            return ChatResponse(id: raw.id, model: raw.model, message: sanitized, raw: raw)
        }
    }
}
