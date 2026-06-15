@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct JinaEnricherTests {
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

    private static func makeEnricher(session: URLSession, apiKey: String? = "test-key") -> JinaEnricher {
        JinaEnricher(session: session, apiKey: apiKey, logger: Logger(label: "test.jina"))
    }

    private static func ok() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://r.jina.ai/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/markdown"]
        )!
    }

    @Test
    func `canHandle returns true for any url`() throws {
        let enricher = Self.makeEnricher(session: Self.stubSession())
        #expect(try enricher.canHandle(url: #require(URL(string: "https://example.com/article"))))
        #expect(try enricher.canHandle(url: #require(URL(string: "https://blog.example.org"))))
    }

    @Test
    func `enrich populates body with jina markdown`() async throws {
        let captured = Captured()
        StubProtocol.handler = { req in
            captured.requests.append(req)
            return .success((Self.ok(), Data("# Article Title\n\nFull body text from jina.".utf8)))
        }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession())
        let url = try #require(URL(string: "https://example.com/article"))
        let metadata = try await enricher.enrich(url: url)

        let req = try #require(captured.requests.first)
        #expect(req.url?.host == "r.jina.ai")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(req.value(forHTTPHeaderField: "Accept") == "text/markdown")
        #expect(metadata.url == url.absoluteString)
        #expect(metadata.body == "# Article Title\n\nFull body text from jina.")
    }

    @Test
    func `enrich without api key omits Authorization header`() async throws {
        let captured = Captured()
        StubProtocol.handler = { req in
            captured.requests.append(req)
            return .success((Self.ok(), Data("body".utf8)))
        }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession(), apiKey: nil)
        _ = try await enricher.enrich(url: #require(URL(string: "https://example.com")))
        let req = try #require(captured.requests.first)
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `enrich caps body at 1MB`() async throws {
        let oversized = String(repeating: "x", count: 2 * 1024 * 1024)
        StubProtocol.handler = { _ in .success((Self.ok(), Data(oversized.utf8))) }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession())
        let metadata = try await enricher.enrich(url: #require(URL(string: "https://example.com")))
        let body = try #require(metadata.body)
        #expect(body.count <= 1024 * 1024)
    }

    @Test
    func `enrich retries once on 429 then succeeds`() async throws {
        let captured = Captured()
        StubProtocol.handler = { req in
            captured.attempts += 1
            if captured.attempts == 1 {
                let tooMany = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: [:])!
                return .success((tooMany, Data()))
            }
            return .success((Self.ok(), Data("recovered".utf8)))
        }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession())
        let metadata = try await enricher.enrich(url: #require(URL(string: "https://example.com")))
        #expect(captured.attempts == 2)
        #expect(metadata.body == "recovered")
    }

    @Test
    func `enrich throws JinaEnricherError after two 429s`() async throws {
        StubProtocol.handler = { req in
            let tooMany = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: "HTTP/1.1", headerFields: [:])!
            return .success((tooMany, Data()))
        }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession())
        await #expect(throws: JinaEnricherError.self) {
            _ = try await enricher.enrich(url: #require(URL(string: "https://example.com")))
        }
    }

    @Test
    func `enrich throws on network error`() async throws {
        StubProtocol.handler = { _ in .failure(URLError(.cannotConnectToHost)) }
        defer { StubProtocol.handler = nil }

        let enricher = Self.makeEnricher(session: Self.stubSession())
        await #expect(throws: (any Error).self) {
            _ = try await enricher.enrich(url: #require(URL(string: "https://example.com")))
        }
    }
}
