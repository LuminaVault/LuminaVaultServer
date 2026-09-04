import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore

/// HER-37 — Server-Sent-Events response generator for streaming
/// `QueryStreamEvent` payloads to the iOS client.
///
/// Wire format: each `data:` line carries one JSON-encoded
/// `QueryStreamEvent`. No `event:` field is used — the JSON payload's
/// `type` field is the discriminator. Records are terminated by a blank
/// line per the SSE spec.
///
///     data: {"type":"token","payload":"hello"}\n
///     \n
///
/// Stream-level errors (encoding failures, upstream LLM failures) are
/// surfaced as a final `.error` event so clients can distinguish them
/// from the normal `.done` terminator.
struct SSEStreamResponse: ResponseGenerator {
    let events: AsyncThrowingStream<QueryStreamEvent, Error>

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let stream = events
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            // Client decodes SSE frames with `.iso8601` dates (JSONDecoder.hvDefault).
            // Without this the default `.deferredToDate` emits a numeric timestamp and
            // the client throws "data couldn't be read…" on the first Date-bearing event
            // (e.g. `.source(QueryHitDTO.createdAt)`). Matches MemoryCompileProgressPublisher.
            encoder.dateEncodingStrategy = .iso8601
            do {
                for try await event in stream {
                    let buf = try Self.encodeEventLine(event, encoder: encoder)
                    try await writer.write(buf)
                }
            } catch {
                // Best-effort error event. If the writer itself is broken
                // there's nothing useful left to do.
                if let buf = try? Self.encodeEventLine(.error("\(error)"), encoder: encoder) {
                    try? await writer.write(buf)
                }
            }
            try await writer.finish(nil)
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        // Disable buffering on reverse proxies (nginx etc.) so token deltas
        // flush incrementally.
        if let name = HTTPField.Name("X-Accel-Buffering") {
            headers[name] = "no"
        }

        return Response(status: .ok, headers: headers, body: body)
    }

    private static func encodeEventLine(
        _ event: QueryStreamEvent,
        encoder: JSONEncoder
    ) throws -> ByteBuffer {
        let json = try encoder.encode(event)
        var buf = ByteBuffer()
        buf.reserveCapacity(json.count + 8)
        buf.writeStaticString("data: ")
        buf.writeBytes(json)
        buf.writeStaticString("\n\n")
        return buf
    }
}

/// Phase 1 — the same wire format as `SSEStreamResponse` for any
/// `Encodable` payload, so surfaces that stream their own DTOs (Hermes run
/// events) do not have to widen `QueryStreamEvent`.
///
/// Differences from `SSEStreamResponse`, both required by a feed that can
/// idle for minutes between events:
///   - a named `event:` line, so browsers can use `addEventListener`;
///   - `: keepalive` comments emitted by the producer are impossible to
///     express through a typed stream, so the caller passes
///     `keepAliveInterval` and this generator writes them itself. Idle
///     proxies (Caddy, nginx, ALB) drop a silent `text/event-stream`
///     connection well before a long agent run finishes.
///
/// A stream-level error is logged by the producer and simply ends the
/// response — the payload type owns its own terminal event.
struct EncodableSSEStreamResponse<Event: Encodable & Sendable>: ResponseGenerator {
    let events: AsyncThrowingStream<Event, Error>
    /// SSE `event:` name written on every record.
    let eventName: String
    let keepAliveInterval: Duration

    init(
        events: AsyncThrowingStream<Event, Error>,
        eventName: String,
        keepAliveInterval: Duration = .seconds(20)
    ) {
        self.events = events
        self.eventName = eventName
        self.keepAliveInterval = keepAliveInterval
    }

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let stream = events
        let name = eventName
        let interval = keepAliveInterval
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            // Clients decode SSE frames with `.iso8601` (JSONDecoder.hvDefault).
            encoder.dateEncodingStrategy = .iso8601
            // Merge the payload stream with a keepalive ticker so an idle
            // run still writes bytes often enough to hold the connection.
            let (merged, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .unbounded)
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await event in stream {
                            continuation.yield(.event(event))
                        }
                    } catch {
                        // Producer already logged; end the response.
                    }
                    continuation.yield(.end)
                }
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: interval)
                        } catch {
                            return
                        }
                        continuation.yield(.keepAlive)
                    }
                }
                loop: for await frame in merged {
                    switch frame {
                    case let .event(event):
                        guard let buf = try? Self.encodeEventLine(event, name: name, encoder: encoder) else {
                            continue
                        }
                        guard await (try? writer.write(buf)) != nil else { break loop }
                    case .keepAlive:
                        var buf = ByteBuffer()
                        buf.writeStaticString(": keepalive\n\n")
                        guard await (try? writer.write(buf)) != nil else { break loop }
                    case .end:
                        break loop
                    }
                }
                group.cancelAll()
                continuation.finish()
            }
            try await writer.finish(nil)
        }

        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        if let name = HTTPField.Name("X-Accel-Buffering") {
            headers[name] = "no"
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    private enum Frame {
        case event(Event)
        case keepAlive
        case end
    }

    static func encodeEventLine(_ event: Event, name: String, encoder: JSONEncoder) throws -> ByteBuffer {
        let json = try encoder.encode(event)
        var buf = ByteBuffer()
        buf.reserveCapacity(json.count + name.utf8.count + 16)
        buf.writeString("event: \(name)\n")
        buf.writeStaticString("data: ")
        buf.writeBytes(json)
        buf.writeStaticString("\n\n")
        return buf
    }
}
