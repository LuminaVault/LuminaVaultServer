import AsyncHTTPClient
import Foundation
import Logging
import NIOCore

/// P2 — shared machinery for native per-token provider streaming.
///
/// Adapters describe the upstream call with a `ProviderStreamRequest`
/// (built asynchronously so per-user credential resolution can run first),
/// and `ProviderStreamKit.run` executes it over `HTTPClient.shared` —
/// `URLSession` has no incremental-body API on Linux's
/// swift-corelibs-foundation (same constraint as
/// `DefaultHermesLLMStreamService`). The body is framed as SSE records or
/// NDJSON lines and each frame is handed to the adapter's `process`
/// closure until it reports the upstream signalled completion.
///
/// Error contract: HTTP/network failures surface as `ProviderError`
/// (classified via `ProviderErrorClassifier`) thrown out of the stream, so
/// `RoutedLLMTransport.chatStream` can fail over exactly like the buffered
/// path — but only when nothing has been yielded yet.
struct ProviderStreamRequest {
    let url: URL
    var headers: [(String, String)] = []
    let body: Data
}

enum ProviderStreamFraming {
    /// `text/event-stream` — records separated by a blank line.
    case sse
    /// One JSON object per newline-terminated line (Ollama).
    case ndjson

    var separator: String {
        switch self {
        case .sse: "\n\n"
        case .ndjson: "\n"
        }
    }
}

enum ProviderStreamKit {
    /// Cap on total streamed bytes so a runaway or malicious upstream
    /// can't exhaust memory. Mirrors `DefaultHermesLLMStreamService`.
    static let maxStreamBytes = 64 * 1024 * 1024

    static func run(
        kind: ProviderKind,
        framing: ProviderStreamFraming,
        httpClient: HTTPClient = .shared,
        timeout: TimeAmount = .seconds(180),
        logger: Logger,
        makeRequest: @escaping @Sendable () async throws -> ProviderStreamRequest,
        process: @escaping @Sendable (String, (ChatStreamChunk) -> Void) throws -> Bool
    ) -> AsyncThrowingStream<ChatStreamChunk, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamChunk, Error>.makeStream()
        let work = Task {
            do {
                let request = try await makeRequest()
                var httpReq = HTTPClientRequest(url: request.url.absoluteString)
                httpReq.method = .POST
                httpReq.headers.add(name: "Content-Type", value: "application/json")
                for (name, value) in request.headers {
                    httpReq.headers.add(name: name, value: value)
                }
                httpReq.body = .bytes(request.body)

                let response: HTTPClientResponse
                do {
                    response = try await httpClient.execute(httpReq, timeout: timeout)
                } catch {
                    throw ProviderError.network(provider: kind, underlying: error)
                }
                let status = Int(response.status.code)
                guard (200 ..< 300).contains(status) else {
                    // Drain a bounded error body so the classifier can spot
                    // credit-exhaustion markers etc.
                    var body = Data()
                    for try await chunk in response.body {
                        if let bytes = chunk.getBytes(at: chunk.readerIndex, length: chunk.readableBytes) {
                            body.append(contentsOf: bytes)
                        }
                        if body.count > 64 * 1024 { break }
                    }
                    let error = ProviderErrorClassifier.classify(provider: kind, status: status, body: body)
                    logger.error("\(kind.rawValue) stream upstream \(error.reasonCode) status=\(status)")
                    throw error
                }

                var buffer = ""
                var finished = false
                var totalBytes = 0
                let separator = framing.separator
                for try await chunk in response.body {
                    if Task.isCancelled { break }
                    totalBytes += chunk.readableBytes
                    if totalBytes > Self.maxStreamBytes {
                        throw ProviderError.transient(
                            provider: kind,
                            status: 0,
                            body: "stream exceeded \(Self.maxStreamBytes) bytes"
                        )
                    }
                    if let text = chunk.getString(at: chunk.readerIndex, length: chunk.readableBytes) {
                        buffer.append(text)
                    }
                    // Pop complete records; keep any partial tail buffered.
                    while let terminator = buffer.range(of: separator) {
                        let record = String(buffer[..<terminator.lowerBound])
                        buffer.removeSubrange(..<terminator.upperBound)
                        if try process(record, { continuation.yield($0) }) {
                            finished = true
                            break
                        }
                    }
                    if finished { break }
                }
                // Flush a trailing record that arrived without its
                // terminator (upstream closed mid-frame).
                if !finished, !buffer.isEmpty {
                    _ = try process(buffer, { continuation.yield($0) })
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in work.cancel() }
        return stream
    }

    /// Set `"stream": true` in an OpenAI chat-completions payload. Falls
    /// through unchanged on parse failure rather than mangling the request.
    static func withStreamFlag(_ payload: Data) -> Data {
        guard var dict = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return payload
        }
        dict["stream"] = true
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? payload
    }

    /// Parse one OpenAI-compatible SSE record (`chat.completion.chunk`).
    /// Handles `[DONE]`, inline `{"error": ...}` payloads, and skips named
    /// non-content events (e.g. Hermes `hermes.tool.progress`). Returns
    /// `true` when the upstream signalled end-of-stream.
    static func processOpenAIRecord(
        _ record: String,
        kind: ProviderKind,
        yield: (ChatStreamChunk) -> Void
    ) throws -> Bool {
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
            if let eventName, eventName != "message" { continue }
            guard
                let data = payload.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let errorObj = obj["error"] as? [String: Any] {
                let message = (errorObj["message"] as? String) ?? "upstream stream error"
                throw ProviderError.transient(provider: kind, status: 0, body: message)
            }
            guard
                let choices = obj["choices"] as? [[String: Any]],
                let choice = choices.first
            else { continue }
            let delta = (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
            let finishReason = choice["finish_reason"] as? String
            if !delta.isEmpty || finishReason != nil {
                yield(ChatStreamChunk(delta: delta, finishReason: finishReason))
            }
            if finishReason != nil { return true }
        }
        return false
    }

    /// Pull `choices[0].message.content` out of a buffered OpenAI response.
    /// Used by the default single-chunk `chatStream` wrap for adapters that
    /// haven't implemented native streaming yet.
    static func extractContent(from data: Data) -> String {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let content = message["content"] as? String
        else { return "" }
        return content
    }
}
