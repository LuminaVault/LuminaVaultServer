@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The cost leak, closed.
///
/// Before this, all four credential resolvers returned the *deployment* env key
/// whenever a BYOK request could not produce a tenant credential — so a user who
/// selected BYOK and never added a key billed the platform for every message.
/// The guard that was supposed to stop it lived only in Cerberus and was bypassed
/// whenever `CERBERUS_EXECUTION_MODE != "active"`.
///
/// The load-bearing assertion in each fail-closed test is not just "it throws" —
/// it is **`requestCount == 0`**: no HTTP request was made, so nothing was spent.
///
/// `@Suite(.serialized)` because `URLProtocol` registration is process-global.
@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct BYOKFailClosedTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with _: URLRequest) -> Bool { handler != nil }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

    /// Thread-safe capture of what actually reached the wire.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []

        func record(_ request: URLRequest) {
            lock.lock(); defer { lock.unlock() }
            _requests.append(request)
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return _requests.count
        }

        var last: URLRequest? {
            lock.lock(); defer { lock.unlock() }
            return _requests.last
        }
    }

    private static let envKey = "PLATFORM-ENV-KEY-DO-NOT-SPEND"

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    /// Installs a handler that records every request and returns a minimal
    /// OpenAI-shaped 200, so a *successful* path completes normally.
    private static func installHandler(_ capture: Capture) {
        StubProtocol.handler = { request in
            capture.record(request)
            let body = Data(#"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body)
        }
    }

    private static let payload = Data(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#.utf8)

    private static func openAICompatible(kind: ProviderKind) -> OpenAICompatibleAdapter {
        OpenAICompatibleAdapter(
            kind: kind,
            apiKey: envKey,
            baseURL: OpenAICompatibleAdapter.defaultBaseURL(for: kind),
            session: session(),
            logger: Logger(label: "test.byok"),
            userCredentials: nil
        )
    }

    // MARK: - Fail closed

    @Test(
        "byok with no resolvable credential throws and spends nothing",
        arguments: [ProviderKind.openRouter, .openai, .xai, .nous, .custom, .nvidia]
    )
    func openAICompatibleFailsClosed(kind: ProviderKind) async {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = Self.openAICompatible(kind: kind)
        await #expect(throws: BYOKKeysRequiredError.self) {
            try await LLMRoutingContext.$credentialMode.withValue(.byok) {
                try await adapter.chatCompletionsWithMetadata(
                    payload: Self.payload, sessionKey: "k", sessionID: nil
                )
            }
        }
        #expect(capture.count == 0, "a BYOK request with no key must never reach the provider")
    }

    @Test("anthropic byok with no resolvable credential throws and spends nothing")
    func anthropicFailsClosed() async {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = AnthropicAdapter(
            apiKey: Self.envKey,
            session: Self.session(),
            logger: Logger(label: "test.byok"),
            userCredentials: nil
        )
        await #expect(throws: BYOKKeysRequiredError.self) {
            try await LLMRoutingContext.$credentialMode.withValue(.byok) {
                try await adapter.chatCompletionsWithMetadata(
                    payload: Self.payload, sessionKey: "k", sessionID: nil
                )
            }
        }
        #expect(capture.count == 0)
    }

    @Test("gemini byok with no resolvable credential throws and spends nothing")
    func geminiFailsClosed() async {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = GeminiContentsAdapter(
            apiKey: Self.envKey,
            session: Self.session(),
            logger: Logger(label: "test.byok"),
            userCredentials: nil
        )
        await #expect(throws: BYOKKeysRequiredError.self) {
            try await LLMRoutingContext.$credentialMode.withValue(.byok) {
                try await adapter.chatCompletionsWithMetadata(
                    payload: Self.payload, sessionKey: "k", sessionID: nil
                )
            }
        }
        #expect(capture.count == 0)
    }

    /// Ollama carries no API key, so this is not a cost leak — but proxying a
    /// BYOK-declared call to the *deployment's* own Ollama is a cross-tenant
    /// correctness and privacy bug.
    @Test("ollama byok with no configured endpoint throws rather than using the deployment host")
    func ollamaFailsClosed() async {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = OllamaAdapter(
            defaultBaseURL: URL(string: "http://localhost:11434")!,
            session: Self.session(),
            logger: Logger(label: "test.byok"),
            userCredentials: nil
        )
        await #expect(throws: BYOKKeysRequiredError.self) {
            try await LLMRoutingContext.$credentialMode.withValue(.byok) {
                try await adapter.chatCompletionsWithMetadata(
                    payload: Self.payload, sessionKey: "k", sessionID: nil
                )
            }
        }
        #expect(capture.count == 0)
    }

    // MARK: - Managed must still work (the regression guard)

    /// The free lane runs as `.managed`, so this path has to keep spending the
    /// platform key. Breaking it would take down every non-paying user.
    @Test("managed mode still uses the deployment key")
    func managedUsesEnvKey() async throws {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = Self.openAICompatible(kind: .openRouter)
        _ = try await LLMRoutingContext.$credentialMode.withValue(.managed) {
            try await adapter.chatCompletionsWithMetadata(
                payload: Self.payload, sessionKey: "k", sessionID: nil
            )
        }
        #expect(capture.count == 1)
        #expect(capture.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.envKey)")
    }

    /// `nil` means no caller declared an intent — internal and cron work with no
    /// user attached. Those are genuinely platform-funded, so managed semantics
    /// are correct and must not regress into a 403.
    @Test("a nil credential mode keeps managed semantics")
    func nilModeKeepsManagedSemantics() async throws {
        let capture = Capture()
        Self.installHandler(capture)
        defer { StubProtocol.handler = nil }

        let adapter = Self.openAICompatible(kind: .openRouter)
        _ = try await adapter.chatCompletionsWithMetadata(
            payload: Self.payload, sessionKey: "k", sessionID: nil
        )
        #expect(capture.count == 1)
        #expect(capture.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.envKey)")
    }
}
