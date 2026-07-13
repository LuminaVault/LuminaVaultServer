@testable import App
import Foundation
import HTTPTypes
import Hummingbird
import LuminaVaultShared
import NIOCore
import Testing

/// HER-37 — unit tests for the streaming query surface. The full
/// `POST /v1/query/stream` route is exercised via end-to-end tests once
/// the iOS client lands; this suite covers the pure pieces that don't
/// require Postgres or a live Hermes gateway.
struct QueryStreamTests {
    // MARK: - Wire format

    private func decodeSSEEvent(_ buf: ByteBuffer) throws -> QueryStreamEvent {
        var b = buf
        let bytes = b.readBytes(length: b.readableBytes) ?? []
        let raw = String(decoding: bytes, as: UTF8.self)
        // Expect exactly "data: <json>\n\n".
        guard raw.hasPrefix("data: "), raw.hasSuffix("\n\n") else {
            throw SSEParseError(reason: "missing data:/terminator", raw: raw)
        }
        let json = raw.dropFirst("data: ".count).dropLast(2)
        let data = Data(json.utf8)
        return try JSONDecoder().decode(QueryStreamEvent.self, from: data)
    }

    private struct SSEParseError: Error {
        let reason: String
        let raw: String
    }

    @Test
    func `SSE token event encodes as data colon json double newline`() async throws {
        let body = ResponseBody { writer in
            let stream = AsyncThrowingStream<QueryStreamEvent, Error> { c in
                c.yield(.token("hello"))
                c.finish()
            }
            // Drive the same path SSEStreamResponse uses — encode and
            // forward each event through the writer.
            let encoder = JSONEncoder()
            for try await event in stream {
                let json = try encoder.encode(event)
                var buf = ByteBuffer()
                buf.writeStaticString("data: ")
                buf.writeBytes(json)
                buf.writeStaticString("\n\n")
                try await writer.write(buf)
            }
            try await writer.finish(nil)
        }
        let written = try await collect(body)
        let decoded = try decodeSSEEvent(written)
        #expect(decoded == .token("hello"))
    }

    @Test
    func `SSE source event round-trips through wire format`() async throws {
        let hit = try QueryHitDTO(
            id: #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            content: "slept 9h on Tuesday",
            distance: 0.21,
            createdAt: nil
        )
        let body = ResponseBody { writer in
            let stream = AsyncThrowingStream<QueryStreamEvent, Error> { c in
                c.yield(.source(hit))
                c.finish()
            }
            let encoder = JSONEncoder()
            for try await event in stream {
                let json = try encoder.encode(event)
                var buf = ByteBuffer()
                buf.writeStaticString("data: ")
                buf.writeBytes(json)
                buf.writeStaticString("\n\n")
                try await writer.write(buf)
            }
            try await writer.finish(nil)
        }
        let written = try await collect(body)
        let decoded = try decodeSSEEvent(written)
        #expect(decoded == .source(hit))
    }

    @Test
    func `done event has no payload key on wire`() throws {
        let json = try JSONEncoder().encode(QueryStreamEvent.done)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(obj?["type"] as? String == "done")
        #expect(obj?.keys.contains("payload") == false)
    }

    // MARK: - Prompt construction

    @Test
    func `buildPrompt embeds hits as numbered context block`() {
        let hits = [
            MemorySearchResult(
                id: UUID(),
                tenantID: UUID(),
                content: "ran 5k Monday",
                createdAt: nil,
                distance: 0.1
            ),
            MemorySearchResult(
                id: UUID(),
                tenantID: UUID(),
                content: "skipped run Tuesday",
                createdAt: nil,
                distance: 0.2
            ),
        ]
        let messages = QueryController.buildPrompt(query: "what runs did I do?", hits: hits)
        #expect(messages.count == 2)
        #expect(messages[0].role == "system")
        #expect(messages[1].role == "user")
        #expect(messages[1].content == "what runs did I do?")
        #expect(messages[0].content.contains("[1] [legacy] ran 5k Monday"))
        #expect(messages[0].content.contains("[2] [legacy] skipped run Tuesday"))
    }

    @Test
    func `buildPrompt with no hits surfaces fallback context`() {
        let messages = QueryController.buildPrompt(query: "what?", hits: [])
        #expect(messages[0].content.contains("no relevant memories"))
    }

    // MARK: - Helpers

    /// Drains a `ResponseBody` produced by the closure-based initializer
    /// into a single `ByteBuffer` so the assertions can inspect raw bytes.
    private func collect(_ body: consuming ResponseBody) async throws -> ByteBuffer {
        let collector = Collector()
        try await body.write(BufferingWriter(collector: collector))
        return collector.buffer
    }

    private final class Collector: @unchecked Sendable {
        var buffer = ByteBuffer()
    }

    private struct BufferingWriter: ResponseBodyWriter {
        let collector: Collector
        mutating func write(_ buffer: ByteBuffer) async throws {
            var b = buffer
            collector.buffer.writeBuffer(&b)
        }

        consuming func finish(_: HTTPFields?) async throws {}
    }
}
