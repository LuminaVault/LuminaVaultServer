@testable import App
import AsyncHTTPClient
import Foundation
import Logging
import NIOHTTP1
import Testing

/// HER-186 — `DefaultHermesLLMStreamService` builds outbound
/// `HTTPClientRequest`s with the same header set as
/// `URLSessionHermesChatTransport`, including the
/// `Authorization: Bearer <key>` header gated on a non-empty `apiKey`
/// and the HER-183 session headers gated on `sessionID`.
///
/// `AsyncHTTPClient` is not URLProtocol-stubbable on Linux, so the
/// header construction is factored into a pure `static` helper
/// (`makeStreamRequest`) and asserted directly. Coverage for the
/// streaming body parsing lives in `QueryStreamTests`.
struct HermesLLMStreamServiceTests {
    private static let url = URL(string: "https://hermes.test/v1/chat/completions")!
    private static let payload: Data = .init(#"{"model":"hermes-3","messages":[],"stream":true}"#.utf8)

    private static func headerValue(_ req: HTTPClientRequest, _ name: String) -> String? {
        req.headers.first(name: name)
    }

    @Test
    func `bearer + session headers are sent when apiKey and sessionID are non-empty`() {
        let req = DefaultHermesLLMStreamService.makeStreamRequest(
            url: Self.url,
            sessionKey: "tenant-uuid",
            sessionID: "conv-123",
            apiKey: "k-test",
            payloadData: Self.payload
        )

        #expect(req.method == .POST)
        #expect(req.url == Self.url.absoluteString)
        #expect(Self.headerValue(req, "Authorization") == "Bearer k-test")
        #expect(Self.headerValue(req, "X-Hermes-Session-Key") == "tenant-uuid")
        #expect(Self.headerValue(req, "X-Hermes-Session-Id") == "conv-123")
        #expect(Self.headerValue(req, "Content-Type") == "application/json")
        #expect(Self.headerValue(req, "Accept") == "text/event-stream")
        #expect(Self.headerValue(req, "X-Hermes-Profile") == nil)
    }

    @Test
    func `bearer header is omitted when apiKey is empty`() {
        let req = DefaultHermesLLMStreamService.makeStreamRequest(
            url: Self.url,
            sessionKey: "tenant-uuid",
            sessionID: nil,
            apiKey: "",
            payloadData: Self.payload
        )

        #expect(Self.headerValue(req, "Authorization") == nil)
        #expect(Self.headerValue(req, "X-Hermes-Session-Key") == "tenant-uuid")
        #expect(Self.headerValue(req, "X-Hermes-Session-Id") == nil)
        #expect(Self.headerValue(req, "Content-Type") == "application/json")
        #expect(Self.headerValue(req, "Accept") == "text/event-stream")
    }

    @Test
    func `session id header is omitted when sessionID is empty string`() {
        let req = DefaultHermesLLMStreamService.makeStreamRequest(
            url: Self.url,
            sessionKey: "tenant-uuid",
            sessionID: "",
            apiKey: "k-test",
            payloadData: Self.payload
        )

        #expect(Self.headerValue(req, "X-Hermes-Session-Id") == nil)
        #expect(Self.headerValue(req, "X-Hermes-Session-Key") == "tenant-uuid")
        #expect(Self.headerValue(req, "Authorization") == "Bearer k-test")
    }

    @Test
    func `stream parser throws when upstream sends error payload`() throws {
        let record = #"data: {"error":{"message":"Provider returned error","code":400}}"#
        let decoder = JSONDecoder()
        var yielded: [ChatStreamChunk] = []

        #expect(throws: HermesStreamUpstreamError.self) {
            try DefaultHermesLLMStreamService.processRecord(
                record,
                decoder: decoder,
                yield: { yielded.append($0) },
                logger: Logger(label: "lv.test.hermes-stream")
            )
        }
        #expect(yielded.isEmpty)
    }

    @Test
    func `empty assistant completion maps to stream error event`() {
        let event = ChatStreamCompletionPolicy.emptyCompletionEvent(
            assistantBuffer: "",
            tokenCount: 0
        )

        #expect(event == .error(ChatStreamCompletionPolicy.emptyResponseMessage))
    }

    @Test
    func `non-empty assistant completion does not map to stream error event`() {
        let event = ChatStreamCompletionPolicy.emptyCompletionEvent(
            assistantBuffer: "Hello",
            tokenCount: 1
        )

        #expect(event == nil)
    }
}
