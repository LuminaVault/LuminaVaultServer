@testable import App
import Foundation
import Logging
import Testing

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
/// Uses a `URLProtocol` stub to capture the outbound request without
/// touching the network. The stub registers globally for the lifetime
/// of a test config and routes any URL request through it.
struct HermesGatewayAdapterTests {
    // MARK: - Capturing URLProtocol stub

    final class CaptureStub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var captured: [URLRequest] = []
        nonisolated(unsafe) static var responseStatus: Int = 200
        nonisolated(unsafe) static var responseBody: Data = Data("{}".utf8)

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.captured.append(request)
            let url = request.url ?? URL(string: "about:blank")!
            let response = HTTPURLResponse(
                url: url,
                statusCode: Self.responseStatus,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"],
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.responseBody)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        static func reset() {
            captured.removeAll()
            responseStatus = 200
            responseBody = Data(#"{"choices":[]}"#.utf8)
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CaptureStub.self]
        return URLSession(configuration: config)
    }

    private static func makeAdapter(session: URLSession) -> HermesGatewayAdapter {
        HermesGatewayAdapter(
            baseURL: URL(string: "https://managed.hermes.test")!,
            session: session,
            logger: Logger(label: "lv.test.adapter"),
        )
    }

    private static let payload: Data = Data(#"{"model":"hermes-3","messages":[]}"#.utf8)

    // MARK: - No task-local → managed default

    @Test
    func `no resolution dispatches to managed baseURL without authorization`() async throws {
        CaptureStub.reset()
        let session = Self.makeSession()
        let adapter = Self.makeAdapter(session: session)

        _ = try await adapter.chatCompletions(payload: Self.payload, profileUsername: "alice")

        #expect(CaptureStub.captured.count == 1)
        let req = CaptureStub.captured[0]
        #expect(req.url?.host == "managed.hermes.test")
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Profile") == "alice")
    }

    // MARK: - User override → user baseURL + auth header

    @Test
    func `user override dispatches to override baseURL with authorization`() async throws {
        CaptureStub.reset()
        let session = Self.makeSession()
        let adapter = Self.makeAdapter(session: session)
        let override = HermesEndpointResolver.Resolution(
            baseURL: URL(string: "https://my-vps.example.com:8642")!,
            authHeader: "Bearer my-secret-token",
            isUserOverride: true,
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, profileUsername: "bob")
        }

        #expect(CaptureStub.captured.count == 1)
        let req = CaptureStub.captured[0]
        #expect(req.url?.host == "my-vps.example.com")
        #expect(req.url?.port == 8642)
        #expect(req.url?.path == "/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer my-secret-token")
        #expect(req.value(forHTTPHeaderField: "X-Hermes-Profile") == "bob")
    }

    // MARK: - isUserOverride=false → managed default (no swap)

    @Test
    func `non-override resolution falls back to managed baseURL`() async throws {
        CaptureStub.reset()
        let session = Self.makeSession()
        let adapter = Self.makeAdapter(session: session)
        let nonOverride = HermesEndpointResolver.Resolution(
            baseURL: URL(string: "https://should-not-be-used.example.com")!,
            authHeader: nil,
            isUserOverride: false,
        )

        try await LLMRoutingContext.$currentResolution.withValue(nonOverride) {
            _ = try await adapter.chatCompletions(payload: Self.payload, profileUsername: "carol")
        }

        #expect(CaptureStub.captured.count == 1)
        let req = CaptureStub.captured[0]
        #expect(req.url?.host == "managed.hermes.test")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - User override without auth header

    @Test
    func `user override with nil authHeader skips the header`() async throws {
        CaptureStub.reset()
        let session = Self.makeSession()
        let adapter = Self.makeAdapter(session: session)
        let override = HermesEndpointResolver.Resolution(
            baseURL: URL(string: "https://my-vps.example.com")!,
            authHeader: nil,
            isUserOverride: true,
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, profileUsername: "dave")
        }

        let req = CaptureStub.captured[0]
        #expect(req.url?.host == "my-vps.example.com")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - User override with empty auth header

    @Test
    func `user override with empty authHeader skips the header`() async throws {
        CaptureStub.reset()
        let session = Self.makeSession()
        let adapter = Self.makeAdapter(session: session)
        let override = HermesEndpointResolver.Resolution(
            baseURL: URL(string: "https://my-vps.example.com")!,
            authHeader: "",
            isUserOverride: true,
        )

        try await LLMRoutingContext.$currentResolution.withValue(override) {
            _ = try await adapter.chatCompletions(payload: Self.payload, profileUsername: "eve")
        }

        let req = CaptureStub.captured[0]
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
