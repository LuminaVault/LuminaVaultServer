@testable import App
import Configuration
import Foundation
import HummingbirdFluent
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// `EMBEDDING_PROVIDER=openrouter` builds the OpenAI-wire adapter against
/// OpenRouter with the platform OpenRouter key the LLM routing reads, and
/// falls back to the deterministic stub when no OpenRouter key is set. The
/// HTTP layer is a URLProtocol stub — no network, no real key.
///
/// Integration-tagged because the active service is wrapped in
/// `EmbeddingUsageTracker`, which records usage in Postgres.
@Suite(.serialized, .tags(.integration), .integrationDatabase, .disabled(if: IntegrationTestEnv.skipIntegration))
struct EmbeddingProviderRegistryTests {
    /// `URLProtocol` is an Objective-C class the loading system instantiates
    /// itself, so the handler has to live in a static. The suite is
    /// `.serialized` and every test clears it in `defer`, so there is never
    /// concurrent access — hence `@unchecked Sendable` / `nonisolated(unsafe)`.
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

        override class func canInit(with _: URLRequest) -> Bool {
            handler != nil
        }

        override class func canonicalRequest(for r: URLRequest) -> URLRequest {
            r
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

    private static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private static func okPayload(dim: Int = 1536) -> Data {
        let json: [String: Any] = [
            "object": "list",
            "model": "openai/text-embedding-3-small",
            "data": [["object": "embedding", "index": 0, "embedding": (0 ..< dim).map { _ in 0.01 }]],
            "usage": ["prompt_tokens": 3, "total_tokens": 3],
        ]
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        let data: Data = {
            if let d = request.httpBody {
                return d
            }
            guard let s = request.httpBodyStream else { return Data() }
            s.open(); defer { s.close() }
            var out = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while s.hasBytesAvailable {
                let n = s.read(buf, maxLength: 4096)
                if n <= 0 {
                    break
                }
                out.append(buf, count: n)
            }
            return out
        }()
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func bootstrap(_ values: [AbsoluteConfigKey: ConfigValue], fluent: Fluent) -> EmbeddingProviderRegistry {
        EmbeddingProviderRegistry.bootstrap(
            reader: ConfigReader(providers: [InMemoryProvider(values: values)]),
            fluent: fluent,
            hermesHandleResolver: { _ in nil },
            session: session(),
            logger: Logger(label: "test.embedding.registry")
        )
    }

    private final class Captured: @unchecked Sendable {
        /// Written once by the stub handler and read after the awaited call
        /// returns, so the accesses never overlap.
        var request: URLRequest?
    }

    @Test
    func `openrouter is selected with the LLM routing's OpenRouter key and calls OpenRouter's embeddings endpoint`() async throws {
        let captured = Captured()
        StubProtocol.handler = { req in
            captured.request = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.okPayload())
        }
        defer { StubProtocol.handler = nil }

        try await withTestFluent(label: "test.embedding.registry.openrouter") { fluent in
            let registry = Self.bootstrap([
                "embedding.provider": cfg("openrouter"),
                "embedding.monthlyTokenCapDefault": cfg(0),
                "llm.provider.openRouter.apiKey": cfg("or-test-key"),
            ], fluent: fluent)
            #expect(registry.activeKind == .openRouter)

            let vector = try await registry.active.embed("hello", tenantID: UUID())
            #expect(vector.count == 1536)
        }

        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/embeddings")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer or-test-key")
        let body = Self.body(of: request)
        #expect(body["model"] as? String == "openai/text-embedding-3-small")
        #expect(body["dimensions"] as? Int == 1536)
        #expect(body["encoding_format"] as? String == "float")
    }

    @Test
    func `every config spelling of the provider selects openrouter`() async throws {
        try await withTestFluent(label: "test.embedding.registry.spellings") { fluent in
            for raw in ["openrouter", "OpenRouter", "open_router", "open-router"] {
                let registry = Self.bootstrap([
                    "embedding.provider": cfg(raw),
                    "llm.provider.openRouter.apiKey": cfg("or-test-key"),
                ], fluent: fluent)
                #expect(registry.activeKind == .openRouter, "\(raw)")
            }
        }
    }

    @Test
    func `the platform fallback OpenRouter key is enough, exactly as for LLM routing`() async throws {
        try await withTestFluent(label: "test.embedding.registry.alias") { fluent in
            let registry = Self.bootstrap([
                "embedding.provider": cfg("openrouter"),
                "openrouter.fallback_api_key": cfg("platform-key"),
            ], fluent: fluent)
            #expect(registry.activeKind == .openRouter)
            #expect(EmbeddingProviderRegistry.openRouterAPIKey(reader: ConfigReader(providers: [InMemoryProvider(values: [
                "openrouter.fallback_api_key": cfg("platform-key"),
            ])])) == "platform-key")
        }
    }

    @Test
    func `without an OpenRouter key the registry falls back to deterministic`() async throws {
        try await withTestFluent(label: "test.embedding.registry.missing") { fluent in
            let registry = Self.bootstrap([
                "embedding.provider": cfg("openrouter"),
                "llm.provider.openRouter.apiKey": cfg("   "),
            ], fluent: fluent)
            #expect(registry.activeKind == .deterministic)
        }
    }

    @Test
    func `base URL and model overrides are honoured`() async throws {
        let captured = Captured()
        StubProtocol.handler = { req in
            captured.request = req
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.okPayload())
        }
        defer { StubProtocol.handler = nil }

        try await withTestFluent(label: "test.embedding.registry.overrides") { fluent in
            let registry = Self.bootstrap([
                "embedding.provider": cfg("openrouter"),
                "embedding.monthlyTokenCapDefault": cfg(0),
                "llm.provider.openRouter.apiKey": cfg("or-test-key"),
                "embedding.openRouter.baseURL": cfg("https://gateway.example.com/openrouter"),
                "embedding.openRouter.model": cfg("openai/text-embedding-3-large"),
            ], fluent: fluent)
            _ = try await registry.active.embed("hello", tenantID: UUID())
        }

        let request = try #require(captured.request)
        #expect(request.url?.absoluteString == "https://gateway.example.com/openrouter/v1/embeddings")
        #expect(Self.body(of: request)["model"] as? String == "openai/text-embedding-3-large")
    }

    @Test
    func `a wrong-width vector from OpenRouter is rejected, never stored`() async throws {
        StubProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.okPayload(dim: 3072))
        }
        defer { StubProtocol.handler = nil }

        try await withTestFluent(label: "test.embedding.registry.dim") { fluent in
            let registry = Self.bootstrap([
                "embedding.provider": cfg("openrouter"),
                "embedding.monthlyTokenCapDefault": cfg(0),
                "llm.provider.openRouter.apiKey": cfg("or-test-key"),
            ], fluent: fluent)
            await #expect(throws: EmbeddingProviderError.dimMismatch(expected: 1536, got: 3072)) {
                _ = try await registry.active.embed("hello", tenantID: UUID())
            }
        }
    }
}
