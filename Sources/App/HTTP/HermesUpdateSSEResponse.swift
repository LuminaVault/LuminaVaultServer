import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore

/// HER-330 — SSE response generator for the Hermes self-update progress
/// stream. Mirrors `SSEStreamResponse` (the memory-query streamer): one
/// JSON-encoded `HermesUpdateEvent` per `data:` line, blank-line terminated,
/// `.iso8601` dates so the client's `JSONDecoder.hvDefault` parses them.
struct HermesUpdateSSEResponse: ResponseGenerator {
    let events: AsyncThrowingStream<HermesUpdateEvent, Error>

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let stream = events
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                for try await event in stream {
                    let buf = try Self.encodeEventLine(event, encoder: encoder)
                    try await writer.write(buf)
                }
            } catch {
                if let buf = try? Self.encodeEventLine(.error("\(error)"), encoder: encoder) {
                    try? await writer.write(buf)
                }
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

    private static func encodeEventLine(
        _ event: HermesUpdateEvent,
        encoder: JSONEncoder,
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
