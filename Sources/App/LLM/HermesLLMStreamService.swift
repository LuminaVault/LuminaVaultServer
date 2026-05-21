import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import Tracing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-37 — single delta produced by a streaming chat completion.
/// Concatenate `delta`s in order to reconstruct the full reply.
/// `finishReason` is non-nil on the terminal chunk.
struct ChatStreamChunk: Equatable {
    let delta: String
    let finishReason: String?

    init(delta: String, finishReason: String? = nil) {
        self.delta = delta
        self.finishReason = finishReason
    }
}

/// HER-37 — streaming counterpart to `HermesLLMService`. Exposes an
/// `AsyncThrowingStream` of `ChatStreamChunk` so callers can forward
/// deltas over SSE without buffering the full reply.
///
/// Note: routed/Gemini streaming is out of scope for HER-37. The default
/// impl hits the central Hermes gateway directly and parses its
/// OpenAI-compatible `text/event-stream` body.
protocol HermesLLMStreamService: Sendable {
    func chatStream(
        profileUsername: String,
        request: ChatRequest,
    ) -> AsyncThrowingStream<ChatStreamChunk, Error>
}

struct DefaultHermesLLMStreamService: HermesLLMStreamService {
    let baseURL: URL
    let session: URLSession
    let defaultModel: String
    let logger: Logger
    /// HER-254 — Bearer key for the central Hermes gateway. Empty skips the header.
    let apiKey: String
    let successCounter = Counter(label: "luminavault.llm.chat.stream.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.stream.failure")

    init(
        baseURL: URL,
        session: URLSession,
        defaultModel: String,
        logger: Logger,
        apiKey: String = "",
    ) {
        self.baseURL = baseURL
        self.session = session
        self.defaultModel = defaultModel
        self.logger = logger
        self.apiKey = apiKey
    }

    func chatStream(
        profileUsername: String,
        request: ChatRequest,
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let baseURL = baseURL
        let session = session
        let defaultModel = defaultModel
        let logger = logger
        let apiKey = apiKey
        let successCounter = successCounter
        let failureCounter = failureCounter

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL
                        .appendingPathComponent("v1")
                        .appendingPathComponent("chat")
                        .appendingPathComponent("completions")
                    var urlReq = URLRequest(url: url)
                    urlReq.httpMethod = "POST"
                    urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlReq.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlReq.setValue(profileUsername, forHTTPHeaderField: "X-Hermes-Profile")
                    if !apiKey.isEmpty {
                        urlReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    }

                    let payload = StreamingChatRequestBody(
                        model: request.model ?? defaultModel,
                        messages: request.messages,
                        temperature: request.temperature,
                        stream: true,
                    )
                    urlReq.httpBody = try JSONEncoder().encode(payload)

                    let (bytes, response) = try await session.bytes(for: urlReq)
                    guard let http = response as? HTTPURLResponse else {
                        failureCounter.increment()
                        continuation.finish(throwing: HTTPError(.badGateway, message: "hermes stream returned no http response"))
                        return
                    }
                    guard (200 ..< 300).contains(http.statusCode) else {
                        failureCounter.increment()
                        logger.error("hermes stream upstream \(http.statusCode)")
                        continuation.finish(throwing: HTTPError(.badGateway, message: "hermes stream upstream error (\(http.statusCode))"))
                        return
                    }

                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        // OpenAI SSE: each event is `data: <json>` with an
                        // optional `[DONE]` sentinel at end. Empty lines
                        // and non-`data:` comments are skipped per spec.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(UpstreamStreamChunk.self, from: data)
                            guard let choice = chunk.choices.first else { continue }
                            let delta = choice.delta.content ?? ""
                            if !delta.isEmpty || choice.finishReason != nil {
                                continuation.yield(ChatStreamChunk(
                                    delta: delta,
                                    finishReason: choice.finishReason,
                                ))
                            }
                            if choice.finishReason != nil { break }
                        } catch {
                            logger.debug("hermes stream chunk decode skipped: \(error)")
                            continue
                        }
                    }
                    successCounter.increment()
                    continuation.finish()
                } catch {
                    failureCounter.increment()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Wire types

private struct StreamingChatRequestBody: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let stream: Bool

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
    }
}

private struct UpstreamStreamChunk: Decodable {
    struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
    }

    let choices: [Choice]
}
