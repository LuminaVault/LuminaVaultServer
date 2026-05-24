@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Timeout hardening for HermesGatewayAdapter. Covers explicit 90s
/// per-request timeout, retry-once-on-timedOut for non-streamed
/// payloads, and no-retry for streamed payloads.
@Suite(.serialized)
struct HermesGatewayTimeoutTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Result<(HTTPURLResponse, Data), URLError>)?

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
            switch handler(request) {
            case let .success((response, data)):
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .failure(urlError):
                client?.urlProtocol(self, didFailWithError: urlError)
            }
        }

        override func stopLoading() {}
    }

    private final class Captured: @unchecked Sendable {
        var requests: [URLRequest] = []
        var attempts: Int = 0
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
            logger: Logger(label: "lv.test.timeout"),
        )
    }

    private static let okResponse: HTTPURLResponse = .init(
        url: URL(string: "https://managed.hermes.test/v1/chat/completions")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"],
    )!
    private static let okBody = Data(#"{"choices":[]}"#.utf8)
    private static let nonStreamPayload = Data(#"{"model":"hermes-3","messages":[],"stream":false}"#.utf8)

    @Test
    func `URLRequest carries explicit 90s timeout interval`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            return .success((Self.okResponse, Self.okBody))
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        _ = try await adapter.chatCompletions(payload: Self.nonStreamPayload, sessionKey: "alice", sessionID: nil)

        let req = try #require(captured.requests.first)
        #expect(req.timeoutInterval == HermesGatewayAdapter.requestTimeoutSeconds, "must match adapter's request timeout constant")
    }

    @Test
    func `non-stream payload retries once on URLError timedOut`() async throws {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            captured.attempts += 1
            if captured.attempts == 1 {
                return .failure(URLError(.timedOut))
            }
            return .success((Self.okResponse, Self.okBody))
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        let data = try await adapter.chatCompletions(
            payload: Self.nonStreamPayload,
            sessionKey: "alice",
            sessionID: nil,
        )
        #expect(captured.attempts == 2, "must retry exactly once after timeout")
        #expect(data == Self.okBody)
    }

    @Test
    func `non-stream payload throws after second timeout`() async {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            captured.attempts += 1
            return .failure(URLError(.timedOut))
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        await #expect(throws: ProviderError.self) {
            _ = try await adapter.chatCompletions(
                payload: Self.nonStreamPayload,
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        #expect(captured.attempts == 2, "exactly two attempts before throwing")
    }

    @Test
    func `stream payload does NOT retry on timedOut`() async {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            captured.attempts += 1
            return .failure(URLError(.timedOut))
        }
        defer { StubProtocol.handler = nil }

        let streamPayload = Data(#"{"model":"hermes-3","messages":[],"stream":true}"#.utf8)
        let adapter = Self.makeAdapter(session: Self.stubSession())
        await #expect(throws: ProviderError.self) {
            _ = try await adapter.chatCompletions(
                payload: streamPayload,
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        #expect(captured.attempts == 1, "streamed requests must not retry")
    }

    @Test
    func `non-timeout URLError does NOT retry`() async {
        let captured = Captured()
        StubProtocol.handler = { request in
            captured.requests.append(request)
            captured.attempts += 1
            return .failure(URLError(.cannotConnectToHost))
        }
        defer { StubProtocol.handler = nil }

        let adapter = Self.makeAdapter(session: Self.stubSession())
        await #expect(throws: ProviderError.self) {
            _ = try await adapter.chatCompletions(
                payload: Self.nonStreamPayload,
                sessionKey: "alice",
                sessionID: nil,
            )
        }
        #expect(captured.attempts == 1, "only timedOut triggers retry, not other URLErrors")
    }
}
