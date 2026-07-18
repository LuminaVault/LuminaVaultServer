import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore

struct WorkflowEventsSSEResponse: ResponseGenerator {
    let store: WorkflowEventStore
    let tenantID: UUID
    let runID: UUID
    let after: Int64
    let isTerminal: @Sendable (UUID, UUID) async -> Bool

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var cursor = after
            do {
                while !Task.isCancelled {
                    let events = try await store.list(tenantID: tenantID, runID: runID, after: cursor)
                    for event in events {
                        cursor = max(cursor, event.id)
                        try await writer.write(Self.encode(event, encoder: encoder))
                    }
                    if await isTerminal(tenantID, runID), events.isEmpty {
                        break
                    }
                    if events.isEmpty {
                        var heartbeat = ByteBuffer()
                        heartbeat.writeStaticString(": keep-alive\n\n")
                        try await writer.write(heartbeat)
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                try await writer.finish(nil)
            } catch is CancellationError {
                try? await writer.finish(nil)
            } catch {
                try? await writer.finish(nil)
            }
        }
        var headers = HTTPFields()
        headers[.contentType] = "text/event-stream"
        headers[.cacheControl] = "no-cache"
        if let name = HTTPField.Name("X-Accel-Buffering") {
            headers[name] = "no"
        }
        return Response(status: .ok, headers: headers, body: body)
    }

    private static func encode(_ event: WorkflowRunEventDTO, encoder: JSONEncoder) throws -> ByteBuffer {
        let data = try encoder.encode(event)
        var buffer = ByteBuffer()
        buffer.reserveCapacity(data.count + 48)
        buffer.writeString("id: \(event.id)\n")
        buffer.writeString("event: \(event.kind.rawValue)\n")
        buffer.writeStaticString("data: ")
        buffer.writeBytes(data)
        buffer.writeStaticString("\n\n")
        return buffer
    }
}
