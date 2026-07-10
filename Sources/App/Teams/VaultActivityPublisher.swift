import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

actor VaultActivityPublisher {
    private var subscribers: [UUID: [UUID: AsyncStream<ActivityResponse>.Continuation]] = [:]

    func subscribe(vaultID: UUID) -> AsyncStream<ActivityResponse> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            subscribers[vaultID, default: [:]][subscriberID] = continuation
            continuation.onTermination = { _ in
                Task { await self.remove(vaultID: vaultID, subscriberID: subscriberID) }
            }
        }
    }

    func publish(_ event: ActivityResponse) {
        guard let continuations = subscribers[event.vaultID]?.values else { return }
        for continuation in continuations {
            continuation.yield(event)
        }
    }

    private func remove(vaultID: UUID, subscriberID: UUID) {
        subscribers[vaultID]?[subscriberID] = nil
        if subscribers[vaultID]?.isEmpty == true {
            subscribers[vaultID] = nil
        }
    }
}

struct VaultActivitySSEResponse: ResponseGenerator {
    let events: AsyncStream<ActivityResponse>

    func response(from _: Request, context _: some RequestContext) throws -> Response {
        let body = ResponseBody { writer in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for await event in events {
                let data = try encoder.encode(event)
                var buffer = ByteBuffer()
                buffer.writeStaticString("id: ")
                buffer.writeString(event.id.uuidString)
                buffer.writeStaticString("\nevent: activity\ndata: ")
                buffer.writeBytes(data)
                buffer.writeStaticString("\n\n")
                try await writer.write(buffer)
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
