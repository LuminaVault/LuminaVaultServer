@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-223 — `HermesGatewayAdapter` honours the BYO Hermes task-local
/// resolution. Asserts that:
///
/// - With no `LLMRoutingContext.currentResolution`, the adapter
///   dispatches against its construction-time `baseURL` and sends no
///   `Authorization` header.
/// - With `currentResolution.isUserOverride == true`, the adapter
///   dispatches against `resolution.baseURL` and forwards
///   `resolution.authHeader` as `Authorization`.
/// - With `isUserOverride == false`, the adapter falls back to the
///   construction-time `baseURL` (managed default) — the override flag
///   gates the swap, not mere presence of a resolution.
///
/// Uses a per-test handler-closure URLProtocol stub. `@Suite(.serialized)`
/// is required because `URLProtocol` registration is process-global; the
/// closure-reset pattern in `defer` prevents cross-test handler leaks
/// even on throw. Matches `OpenAITTSAdapterTests`.
@Suite(.serialized)
struct HermesGatewayAdapterTests {
    // MARK: - URLProtocol stub

    /// Concurrency-safe per-test handler injection. Each test installs its
    /// own handler before kicking off a request; `defer { handler = nil }`
    /// resets afterward so state cannot leak between tests.
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
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

    /// Thread-safe request capture for assertions after the await returns.
    /// `startLoading` runs synchronously before the awaiting Task resumes,
    /// so there is no concurrent access in practice — `@unchecked Sendable`
    /// is correct here.
    private final class Captured: @unchecked Sendable {
        var requests: [URLRequest] = []
    }

    private static func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static func makeAdapter(session: URLSession) -> HermesGatewayAdapter {
        HermesGatewayAdapter(
            baseURL: URL(string: "https://managed.hermes.test")!,
            session: session,
            logger: Logger(label: "lv.test.adapter")
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

    // MARK: - No task-local → managed default

    @Test
    func `no resolution dispatches to managed baseURL without authorization`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "alice", sessionID: nil)

        #expect(captured.requests.count == 1)
        let req = captured.requests[0]
        #expect(req.url?.host == "managed.hermes.test")
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "alice")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Id") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Profile") == nil)
    }

    // MARK: - HER-254 — managed default Bearer header

    @Test
    func `defaultAuthHeader sends Authorization when no override is in scope`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let baseURL = try #require(URL(string: "https://managed.hermes.test"))
        let adapter = HermesGatewayAdapter(
            baseURL: baseURL,
            session: Self.stubSession(),
            logger: Logger(label: "lv.test.adapter.her254"),
            defaultAuthHeader: "Bearer her254-key"
        )
        _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "elise", sessionID: nil)

        #expect(captured.requests.count == 1)
        #expect(captured.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer her254-key")
    }

    @Test
    func `user override masks the defaultAuthHeader`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let baseURL = try #require(URL(string: "https://managed.hermes.test"))
        let adapter = HermesGatewayAdapter(
            baseURL: baseURL,
            session: Self.stubSession(),
            logger: Logger(label: "lv.test.adapter.her254-mask"),
            defaultAuthHeader: "Bearer central-key"
        )
        let override = try HermesEndpointResolver.Resolution(
            baseURL: #require(URL(string: "https://my-vps.example.com")),
            authHeader: "Bearer user-token",
            isUserOverride: true
        )
        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "fred", sessionID: nil)
        }

        #expect(captured.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
        #expect(captured.requests[0].url?.host == "my-vps.example.com")
    }

    // MARK: - User override → user baseURL + auth header

    @Test
    func `user override dispatches to override baseURL with authorization`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let override = try HermesEndpointResolver.Resolution(
            baseURL: #require(URL(string: "https://my-vps.example.com:8642")),
            authHeader: "Bearer my-secret-token",
            isUserOverride: true
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "bob", sessionID: nil)
        }

        #expect(captured.requests.count == 1)
        let req = captured.requests[0]
        #expect(req.url?.host == "my-vps.example.com")
        #expect(req.url?.port == 8642)
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret-token")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "bob")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Profile") == nil)
    }

    // MARK: - isUserOverride=false → managed default (no swap)

    @Test
    func `non-override resolution falls back to managed baseURL`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let nonOverride = try HermesEndpointResolver.Resolution(
            baseURL: #require(URL(string: "https://should-not-be-used.example.com")),
            authHeader: nil,
            isUserOverride: false
        )

        try await LLMRoutingContext.$currentResolution.withValue(nonOverride) {
            _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "carol", sessionID: nil)
        }

        #expect(captured.requests.count == 1)
        let req = captured.requests[0]
        #expect(req.url?.host == "managed.hermes.test")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - User override without auth header

    @Test
    func `user override with nil authHeader skips the header`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let override = try HermesEndpointResolver.Resolution(
            baseURL: #require(URL(string: "https://my-vps.example.com")),
            authHeader: nil,
            isUserOverride: true
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "dave", sessionID: nil)
        }

        let req = captured.requests[0]
        #expect(req.url?.host == "my-vps.example.com")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - User override with empty auth header

    @Test
    func `user override with empty authHeader skips the header`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let override = try HermesEndpointResolver.Resolution(
            baseURL: #require(URL(string: "https://my-vps.example.com")),
            authHeader: "",
            isUserOverride: true
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "eve", sessionID: nil)
        }

        let req = captured.requests[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - HER-183 — X-Hermes-Session-Id conditional

    @Test
    func `non-nil sessionID sets X-Hermes-Session-Id header`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let conversationID = "11111111-2222-3333-4444-555555555555"
        _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "alice", sessionID: conversationID)

        let req = captured.requests[0]
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "alice")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Id") == conversationID)
    }

    @Test
    func `empty sessionID omits the X-Hermes-Session-Id header`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return (Self.okResponse(for: request.url!), Self.okBody)
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        _ = try await adapter.chatCompletions(payload: Self.payload, sessionKey: "alice", sessionID: "")

        let req = captured.requests[0]
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Key") == "alice")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Session-Id") == nil)
    }
}
