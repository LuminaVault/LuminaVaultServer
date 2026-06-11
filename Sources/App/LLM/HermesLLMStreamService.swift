import AsyncHTTPClient
import Foundation
import Hummingbird
import Logging
import LuminaVaultShared
import Metrics
import NIOConcurrencyHelpers
import NIOCore
import Tracing

/// HER — thrown by the streaming service when the upstream sends no bytes
/// for longer than the configured idle window. Converts a silent indefinite
/// hang (Hermes stalled mid-turn) into a fast, labeled failure the chat
/// handler can surface as a `.error` SSE event.
struct HermesStreamIdleTimeout: Error, CustomStringConvertible {
    let seconds: Double
    var description: String {
        "hermes stream idle timeout: no data for \(seconds)s"
    }
}

/// Thrown when the upstream SSE body carries an OpenAI-compatible
/// `{"error": ...}` payload. Without this, provider failures that arrive
/// after the HTTP 200 headers look like an empty successful stream.
struct HermesStreamUpstreamError: Error, CustomStringConvertible {
    let message: String
    let code: String?

    var description: String {
        if let code, !code.isEmpty {
            return "hermes stream upstream error \(code): \(message)"
        }
        return "hermes stream upstream error: \(message)"
    }
}

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
        request: ChatRequest
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
    /// Idle (inter-chunk) timeout. The `requestTimeout` above bounds the
    /// whole exchange, but once Hermes sends `200` + headers and then stalls
    /// (agentic tool execution with no `delta.content`, or a wedged upstream)
    /// nothing fires for the full request budget and the client hangs. This
    /// bounds the gap between received body chunks instead — any received
    /// byte (including `hermes.tool.progress` keep-alives) resets it.
    let streamIdleTimeout: TimeAmount
    let successCounter = Counter(label: "luminavault.llm.chat.stream.success")
    let failureCounter = Counter(label: "luminavault.llm.chat.stream.failure")

    init(
        baseURL: URL,
        httpClient: HTTPClient,
        defaultModel: String,
        logger: Logger,
        apiKey: String = "",
        requestTimeout: TimeAmount = .seconds(120),
        streamIdleTimeout: TimeAmount = .seconds(60)
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.defaultModel = defaultModel
        self.logger = logger
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.streamIdleTimeout = streamIdleTimeout
    }

    func chatStream(
        sessionKey: String,
        sessionID: String?,
        request: ChatRequest
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let baseURL = baseURL
        let httpClient = httpClient
        let defaultModel = defaultModel
        let logger = logger
        let apiKey = apiKey
        let requestTimeout = requestTimeout
        let streamIdleTimeout = streamIdleTimeout
        let successCounter = successCounter
        let failureCounter = failureCounter
        let model = request.model ?? defaultModel

        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            let startedNanos = DispatchTime.now().uptimeNanoseconds
            func elapsedMs() -> Int64 {
                Int64((DispatchTime.now().uptimeNanoseconds - startedNanos) / 1_000_000)
            }
            do {
                // BYO-Hermes: when the per-tenant resolver picked a user
                // override, stream from that endpoint with its own auth header
                // instead of the central gateway. The work Task inherits the
                // `currentResolution` task-local bound by HermesResolutionMiddleware
                // at the request scope. Mirrors HermesGatewayAdapter:57-64.
                let resolution = LLMRoutingContext.currentResolution
                let isOverride = resolution?.isUserOverride == true
                let dispatchBaseURL = isOverride ? (resolution?.baseURL ?? baseURL) : baseURL
                let url = dispatchBaseURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("chat")
                    .appendingPathComponent("completions")

                let payload = StreamingChatRequestBody(
                    model: model,
                    messages: request.messages,
                    temperature: request.temperature,
                    stream: true
                )
                let payloadData = try JSONEncoder().encode(payload)

                let httpReq = Self.makeStreamRequest(
                    url: url,
                    sessionKey: sessionKey,
                    sessionID: sessionID,
                    apiKey: isOverride ? "" : apiKey,
                    payloadData: payloadData,
                    authHeaderOverride: isOverride ? resolution?.authHeader : nil
                )

                logger.debug("hermes stream request", metadata: [
                    "url": .string(url.absoluteString),
                    "model": .string(model),
                    "stream": .string("true"),
                    "session_key_present": .string(sessionKey.isEmpty ? "false" : "true"),
                    "session_id_present": .string((sessionID?.isEmpty == false) ? "true" : "false"),
                    "body_bytes": .stringConvertible(payloadData.count),
                    "idle_timeout_s": .stringConvertible(Double(streamIdleTimeout.nanoseconds) / 1_000_000_000),
                ])

                let response = try await httpClient.execute(httpReq, timeout: requestTimeout)
                guard (200 ..< 300).contains(Int(response.status.code)) else {
                    failureCounter.increment()
                    logger.error("hermes stream upstream non-2xx", metadata: [
                        "status": .stringConvertible(response.status.code),
                        "elapsed_ms": .stringConvertible(elapsedMs()),
                    ])
                    continuation.finish(throwing: HTTPError(.badGateway, message: "hermes stream upstream error (\(response.status.code))"))
                    return
                }

                // Idle watchdog: race the SSE reader against an inactivity
                // timer. Any received body chunk refreshes `lastActivity`;
                // if the gap exceeds `streamIdleTimeout` the watchdog throws,
                // the group cancels the reader, and we surface a labeled
                // timeout instead of hanging until the client gives up.
                let lastActivity = NIOLockedValueBox(NIODeadline.now())
                let idleNanos = streamIdleTimeout.nanoseconds

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var buffer = ""
                        let decoder = JSONDecoder()
                        var finished = false
                        var rawChunks = 0
                        // SSRF/abuse hardening: cap total streamed bytes so a
                        // malicious or runaway (e.g. BYO) endpoint can't exhaust
                        // memory. A real chat turn is far under this.
                        var totalBytes = 0
                        let maxStreamBytes = 64 * 1024 * 1024
                        for try await chunk in response.body {
                            if Task.isCancelled { break }
                            lastActivity.withLockedValue { $0 = .now() }
                            rawChunks += 1
                            totalBytes += chunk.readableBytes
                            if totalBytes > maxStreamBytes {
                                throw HTTPError(.badGateway, message: "hermes stream exceeded \(maxStreamBytes) bytes")
                            }
                            if let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) {
                                buffer.append(text)
                            }
                            // OpenAI SSE: events terminated by `\n\n`. Pop
                            // complete records out of the buffer; leave any
                            // partial tail in place.
                            while let terminator = buffer.range(of: "\n\n") {
                                let record = String(buffer[..<terminator.lowerBound])
                                buffer.removeSubrange(..<terminator.upperBound)
                                if try Self.processRecord(
                                    record,
                                    decoder: decoder,
                                    yield: { continuation.yield($0) },
                                    logger: logger
                                ) {
                                    finished = true
                                    break
                                }
                            }
                            if finished { break }
                        }
                        // Flush a trailing record that arrived without the
                        // `\n\n` terminator (upstream closed mid-frame).
                        if !finished, !buffer.isEmpty {
                            _ = try Self.processRecord(
                                buffer,
                                decoder: decoder,
                                yield: { continuation.yield($0) },
                                logger: logger
                            )
                        }
                        logger.debug("hermes stream reader done", metadata: [
                            "raw_chunks": .stringConvertible(rawChunks),
                            "finished": .string("\(finished)"),
                        ])
                    }
                    group.addTask {
                        while true {
                            try await Task.sleep(for: .milliseconds(1000))
                            if Task.isCancelled { return }
                            let idle = NIODeadline.now() - lastActivity.withLockedValue { $0 }
                            if idle.nanoseconds > idleNanos {
                                throw HermesStreamIdleTimeout(seconds: Double(idleNanos) / 1_000_000_000)
                            }
                        }
                    }
                    // First child to finish wins: reader returns on stream
                    // end, or the watchdog throws on stall. Either way cancel
                    // the rest.
                    try await group.next()
                    group.cancelAll()
                }
                successCounter.increment()
                continuation.finish()
            } catch {
                failureCounter.increment()
                logger.error("hermes stream failed", metadata: [
                    "error": .string(Logger.redact(String(describing: error))),
                    "elapsed_ms": .stringConvertible(elapsedMs()),
                ])
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
        authHeaderOverride: String? = nil
    ) -> HTTPClientRequest {
        var httpReq = HTTPClientRequest(url: url.absoluteString)
        httpReq.method = .POST
        httpReq.headers.add(name: "Content-Type", value: "application/json")
        httpReq.headers.add(name: "Accept", value: "text/event-stream")
        httpReq.headers.add(name: "X-Hermes-Session-Key", value: sessionKey)
        if let sessionID, !sessionID.isEmpty {
            httpReq.headers.add(name: "X-Hermes-Session-Id", value: sessionID)
        }
        // BYO-Hermes: a resolved override carries its own full Authorization
        // value (scheme included) and wins; otherwise fall back to the central
        // gateway's Bearer key. An empty `apiKey` with no override = no header.
        if let authHeaderOverride, !authHeaderOverride.isEmpty {
            httpReq.headers.add(name: "Authorization", value: authHeaderOverride)
        } else if !apiKey.isEmpty {
            httpReq.headers.add(name: "Authorization", value: "Bearer \(apiKey)")
        }
        httpReq.body = .bytes(payloadData)
        return httpReq
    }

    /// Parses one `data: ...` SSE record. Returns `true` when the
    /// upstream signalled end-of-stream (either `[DONE]` or
    /// `finish_reason`).
    static func processRecord(
        _ record: String,
        decoder: JSONDecoder,
        yield: (ChatStreamChunk) -> Void,
        logger: Logger
    ) throws -> Bool {
        // Hermes frames a record as an optional `event:` line followed by
        // `data:`. We forward `chat.completion.chunk` deltas; the custom
        // `hermes.tool.progress` event (and any other non-delta event) is
        // logged for visibility but not treated as content — crucially, the
        // raw byte already refreshed the idle watchdog, so tool work counts
        // as liveness rather than a stall.
        var eventName: String?
        for rawLine in record.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { return true }
            if let eventName, eventName != "message" {
                logger.debug("hermes stream non-content event", metadata: ["event": .string(eventName)])
                continue
            }
            guard let data = payload.data(using: .utf8) else { continue }
            if let upstreamError = try? decoder.decode(UpstreamStreamErrorEnvelope.self, from: data) {
                logger.error("hermes stream upstream error payload", metadata: [
                    "code": .string(upstreamError.error.code ?? "unknown"),
                    "message": .string(Logger.redact(upstreamError.error.message)),
                ])
                throw HermesStreamUpstreamError(
                    message: upstreamError.error.message,
                    code: upstreamError.error.code
                )
            }
            do {
                let chunk = try decoder.decode(UpstreamStreamChunk.self, from: data)
                guard let choice = chunk.choices.first else {
                    logger.trace("hermes stream record had no choices")
                    continue
                }
                let delta = choice.delta.content ?? ""
                if !delta.isEmpty || choice.finishReason != nil {
                    yield(ChatStreamChunk(delta: delta, finishReason: choice.finishReason))
                }
                if choice.finishReason != nil { return true }
            } catch {
                logger.debug("hermes stream chunk decode skipped", metadata: [
                    "event": .string(eventName ?? "none"),
                    "error": .string(String(describing: error)),
                ])
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

private struct UpstreamStreamErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String
        let code: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? "upstream error"
            if let stringCode = try? c.decodeIfPresent(String.self, forKey: .code) {
                code = stringCode
            } else if let intCode = try? c.decodeIfPresent(Int.self, forKey: .code) {
                code = String(intCode)
            } else {
                code = nil
            }
        }

        private enum CodingKeys: String, CodingKey {
            case message, code
        }
    }

    let error: Payload
}
