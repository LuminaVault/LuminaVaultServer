import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore

struct KnowledgeReasoningSSEResponse: ResponseGenerator {
    let events: AsyncThrowingStream<ReasoningStreamEventDTO, Error>

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let events = events
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                for try await event in events {
                    var buffer = ByteBuffer()
                    buffer.writeStaticString("data: ")
                    try buffer.writeBytes(encoder.encode(event))
                    buffer.writeStaticString("\n\n")
                    try await writer.write(buffer)
                }
            } catch {
                var buffer = ByteBuffer()
                buffer.writeStaticString("data: ")
                if let data = try? encoder.encode(ReasoningStreamEventDTO(type: "error", message: String(describing: error))) {
                    buffer.writeBytes(data)
                    buffer.writeStaticString("\n\n")
                    try? await writer.write(buffer)
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
}
