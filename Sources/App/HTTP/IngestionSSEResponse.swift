import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore

struct IngestionSSEResponse: ResponseGenerator {
    let service: MultimodalIngestionService
    let tenantID: UUID
    let batchID: UUID
    let after: Int64

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let body = ResponseBody { writer in
            var cursor = after
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for _ in 0 ..< 360 {
                let events = try await service.events(tenantID: tenantID, batchID: batchID, after: cursor)
                for event in events {
                    let data = try encoder.encode(event)
                    var buffer = ByteBuffer()
                    buffer.writeStaticString("id: ")
                    buffer.writeString(String(event.id))
                    buffer.writeStaticString("\nevent: ingestion\ndata: ")
                    buffer.writeBytes(data)
                    buffer.writeStaticString("\n\n")
                    try await writer.write(buffer)
                    cursor = event.id
                }
                if try await service.isTerminal(tenantID: tenantID, batchID: batchID) {
                    break
                }
                if events.isEmpty {
                    let heartbeat = ByteBuffer(string: ": heartbeat\n\n")
                    try await writer.write(heartbeat)
                }
                try await Task.sleep(for: .seconds(2))
            }
            try await writer.finish(nil)
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        headers[HTTPField.Name("X-Accel-Buffering")!] = "no"
        return Response(status: .ok, headers: headers, body: body)
    }
}
