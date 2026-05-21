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
