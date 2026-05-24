import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import NIOCore
import Tracing

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
/// Routed/Gemini streaming is out of scope for HER-37. The default impl
/// hits the central Hermes gateway directly and parses its OpenAI-
/// compatible `text/event-stream` body.
///
/// Uses `AsyncHTTPClient` rather than `URLSession.bytes(for:)` because
/// the latter is not available on Linux's swift-corelibs-foundation.
protocol HermesLLMStreamService: Sendable {
    /// HER-183 — `sessionKey` is the tenant UUID string
    /// (`X-Hermes-Session-Key`). `sessionID` is optional conversation
    /// continuity (`X-Hermes-Session-Id`).
    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest,
    ) -> AsyncThrowingStream<ChatStreamChunk, Error>
}

struct DefaultHermesLLMStreamService: HermesLLMStreamService {
    let baseURL: URL
    let httpClient: HTTPClient
    let defaultModel: String
    let logger: Logger
    /// HER-254 — Bearer key for the central Hermes gateway. Empty skips
    /// the header.
    let apiKey: String
    let requestTimeout: TimeAmount
    let successCounter = Counter(label: "luminavault.llm.chat.stream.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.stream.failure")

    init(
        baseURL: URL,
        httpClient: HTTPClient,
        defaultModel: String,
        logger: Logger,
        apiKey: String = "",
        requestTimeout: TimeAmount = .seconds(120),
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.defaultModel = defaultModel
        self.logger = logger
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
    }

    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest,
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let baseURL = baseURL
        let httpClient = httpClient
        let defaultModel = defaultModel
        let logger = logger
        let apiKey = apiKey
        let requestTimeout = requestTimeout
        let successCounter = successCounter
        let failureCounter = failureCounter

        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                let url = baseURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("chat")
                    .appendingPathComponent("completions")

                let payload = StreamingChatRequestBody(
                    model: request.model ?? defaultModel,
                    messages: request.messages,
                    temperature: request.temperature,
                    stream: true,
                )
                let payloadData = try JSONEncoder().encode(payload)

                let httpReq = Self.makeStreamRequest(
                    url: url,
                    sessionKey: sessionKey,
                    sessionID: sessionID,
                    apiKey: apiKey,
                    payloadData: payloadData,
                )

                let response = try await httpClient.execute(httpReq, timeout: requestTimeout)
                guard (200 ..< 300).contains(Int(response.status.code)) else {
                    failureCounter.increment()
                    logger.error("hermes stream upstream \(response.status.code)")
                    continuation.finish(throwing: HTTPError(.badGateway, message: "hermes stream upstream error (\(response.status.code))"))
                    return
                }

                var buffer = ""
                let decoder = JSONDecoder()
                var finished = false
                for try await chunk in response.body {
                    if Task.isCancelled { break }
                    if let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) {
                        buffer.append(text)
                    }
                    // OpenAI SSE: events terminated by `\n\n`. Pop
                    // complete records out of the buffer; leave any
                    // partial tail in place.
                    while let terminator = buffer.range(of: "\n\n") {
                        let record = String(buffer[..<terminator.lowerBound])
                        buffer.removeSubrange(..<terminator.upperBound)
                        if Self.processRecord(
                            record,
                            decoder: decoder,
                            yield: { continuation.yield($0) },
                            logger: logger,
                        ) {
                            finished = true
                            break
                        }
                    }
                    if finished { break }
                }
                successCounter.increment()
                continuation.finish()
            } catch {
                failureCounter.increment()
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// HER-186 — builds the streaming chat-completions request with all
    /// headers attached. Extracted so the header wiring (notably the
    /// `Authorization: Bearer` injection and the HER-183 session
    /// headers) can be unit-tested without standing up an `HTTPClient`.
    /// Empty `apiKey` skips the `Authorization` header so
    /// dev / un-gated upstreams keep working; nil or empty `sessionID`
    /// skips `X-Hermes-Session-Id` (one-shot internal callers).
    static func makeStreamRequest(
        url: URL,
        sessionKey: String,
        sessionID: String?,
        apiKey: String,
        payloadData: Data,
    ) -> HTTPClientRequest {
        var httpReq = HTTPClientRequest(url: url.absoluteString)
        httpReq.method = .POST
        httpReq.headers.add(name: "Content-Type", value: "application/json")
        httpReq.headers.add(name: "Accept", value: "text/event-stream")
        httpReq.headers.add(name: "X-Hermes-Session-Key", value: sessionKey)
        if let sessionID, !sessionID.isEmpty {
            httpReq.headers.add(name: "X-Hermes-Session-Id", value: sessionID)
        }
        if !apiKey.isEmpty {
            httpReq.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }
        httpReq.body = .bytes(payloadData)
        return httpReq
    }

    /// Parses one `data: ...` SSE record. Returns `true` when the
    /// upstream signalled end-of-stream (either `[DONE]` or
    /// `finish_reason`).
    private static func processRecord(
        _ record: String,
        decoder: JSONDecoder,
        yield: (ChatStreamChunk) -> Void,
        logger: Logger,
    ) -> Bool {
        for rawLine in record.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { return true }
            guard let data = payload.data(using: .utf8) else { continue }
            do {
                let chunk = try decoder.decode(UpstreamStreamChunk.self, from: data)
                guard let choice = chunk.choices.first else { continue }
                let delta = choice.delta.content ?? ""
                if !delta.isEmpty || choice.finishReason != nil {
                    yield(ChatStreamChunk(delta: delta, finishReason: choice.finishReason))
                }
                if choice.finishReason != nil { return true }
            } catch {
                logger.debug("hermes stream chunk decode skipped: \(error)")
                continue
            }
        }
        return false
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
