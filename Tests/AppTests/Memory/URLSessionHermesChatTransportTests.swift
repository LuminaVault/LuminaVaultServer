@testable import App
import Foundation
import Hummingbird
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-186 — `URLSessionHermesChatTransport` builds outbound URLRequests
/// with the right headers, including the `Authorization: Bearer <key>`
/// header gated on a non-empty `apiKey`. Also asserts the HER-183
/// `X-Hermes-Session-Key` / `X-Hermes-Session-Id` semantics survive the
/// auth wiring. Mirrors the `HermesGatewayAdapterTests` URLProtocol-stub
/// pattern; `.serialized` because `URLProtocol` registration is
/// process-global.
@Suite(.serialized)
struct URLSessionHermesChatTransportTests {
    // MARK: - URLProtocol stub

    /// Separate class from `HermesGatewayAdapterTests.StubProtocol` to
    /// avoid handler-closure races even with `.serialized` — each suite
    /// owns its own static slot.
    private final class MemoryStubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with _: URLRequest) -> Bool {
            handler != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let (response, data) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private final class Captured: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private static func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MemoryStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static func makeTransport(apiKey: String) -> URLSessionHermesChatTransport {
        URLSessionHermesChatTransport(
            baseURL: URL(string: "https://hermes.test")!,
            session: stubSession(),
            logger: Logger(label: "lv.test.memory.transport"),
            apiKey: apiKey
        )
    }

    private static let payload: Data = .init(#"{"model":"hermes-3","messages":[]}"#.utf8)

    private static func okResponse(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private static let okBody: Data = .init(#"{"choices":[]}"#.utf8)

    // MARK: - Bearer header present when apiKey is set

    @Test
    func `bearer header is sent when apiKey is non-empty`() async throws {
        let captured = Captured()
        MemoryStubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { MemoryStubProtocol.handler = nil }

        let transport = Self.makeTransport(apiKey: "k-test")
        _ = try await transport.chatCompletions(payload: Self.payload, sessionKey: "tenant-uuid", sessionID: "conv-123")

        #expect(captured.requests.count == 1)
        let req = captured.requests[0]
        #expect(req.httpMethod == "POST")
        #expect(req.url?.host == "hermes.test")
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k-test")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "tenant-uuid")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Id") == "conv-123")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Profile") == nil)
    }

    // MARK: - Bearer header absent when apiKey is empty (dev path)

    @Test
    func `bearer header is omitted when apiKey is empty`() async throws {
        let captured = Captured()
        MemoryStubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { MemoryStubProtocol.handler = nil }

        let transport = Self.makeTransport(apiKey: "")
        _ = try await transport.chatCompletions(payload: Self.payload, sessionKey: "tenant-uuid", sessionID: nil)

        #expect(captured.requests.count == 1)
        let req = captured.requests[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "tenant-uuid")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Id") == nil)
    }

    // MARK: - 401 upstream surfaces as HTTPError(.badGateway)

    @Test
    func `non-2xx upstream surfaces HTTPError badGateway`() async throws {
        MemoryStubProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (resp, Data("unauthorized".utf8))
        }
        defer { MemoryStubProtocol.handler = nil }

        let transport = Self.makeTransport(apiKey: "k-test")
        await #expect(throws: HTTPError.self) {
            _ = try await transport.chatCompletions(payload: Self.payload, sessionKey: "tenant-uuid", sessionID: nil)
        }
    }
}
