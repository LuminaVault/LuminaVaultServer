@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-134 — OpenAI embedding adapter HTTP contract: request shape,
/// auth header, dim assertion, error classification. URLProtocol stub
/// mirrors `HermesGatewayAdapterTests`.
@Suite(.serialized)
struct OpenAIEmbeddingServiceTests {
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

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    private func okPayload(dim: Int = 1536, tokens: Int = 7) -> Data {
        let vec = (0 ..< dim).map { _ in Float(0.01) }
        let json: [String: Any] = [
            "data": [["embedding": vec]],
            "usage": ["total_tokens": tokens],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test
    func `request shape: POST /v1/embeddings, model + dimensions, Bearer auth`() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        StubProtocol.handler = { req in
            captured = req
            let body = okPayload()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        defer { StubProtocol.handler = nil }

        let svc = try OpenAIEmbeddingService(
            apiKey: "sk-test",
            baseURL: #require(URL(string: "https://api.example.com")),
            model: "text-embedding-3-small",
            session: makeSession(),
        )
        let v = try await svc.embed("hello", tenantID: UUID())
        #expect(v.count == 1536)

        let req = try #require(captured)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/v1/embeddings")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")

        // URLSession with custom URLProtocol uploads via httpBodyStream, not httpBody.
        let body: Data = {
            if let d = req.httpBody { return d }
            guard let s = req.httpBodyStream else { return Data() }
            s.open(); defer { s.close() }
            var out = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while s.hasBytesAvailable {
                let n = s.read(buf, maxLength: 4096)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            return out
        }()
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
        #expect(decoded["model"] as? String == "text-embedding-3-small")
        #expect(decoded["input"] as? String == "hello")
        #expect(decoded["dimensions"] as? Int == 1536)
        #expect(decoded["encoding_format"] as? String == "float")
    }

    @Test
    func `missing API key throws .permanent(.missingAPIKey)`() async {
        let svc = OpenAIEmbeddingService(apiKey: "", session: makeSession())
        await #expect(throws: EmbeddingProviderError.self) {
            _ = try await svc.embed("x", tenantID: UUID())
        }
    }

    @Test
    func `HTTP 429 → .transient (fallback eligible)`() async throws {
        StubProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        defer { StubProtocol.handler = nil }
        let svc = try OpenAIEmbeddingService(apiKey: "sk", baseURL: #require(URL(string: "https://api.example.com")), session: makeSession())
        do {
            _ = try await svc.embed("x", tenantID: UUID())
            Issue.record("expected throw")
        } catch let e as EmbeddingProviderError {
            #expect(e.isRecoverable)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test
    func `HTTP 401 → .permanent(.authRejected)`() async throws {
        StubProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        defer { StubProtocol.handler = nil }
        let svc = try OpenAIEmbeddingService(apiKey: "sk", baseURL: #require(URL(string: "https://api.example.com")), session: makeSession())
        do {
            _ = try await svc.embed("x", tenantID: UUID())
            Issue.record("expected throw")
        } catch let e as EmbeddingProviderError {
            #expect(!e.isRecoverable)
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test
    func `usage callback receives token count from response`() async throws {
        StubProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, okPayload(tokens: 42))
        }
        defer { StubProtocol.handler = nil }

        actor Captured {
            var value: (UUID, Int64)?
            func set(_ v: (UUID, Int64)) {
                value = v
            }
        }
        let cap = Captured()
        let svc = try OpenAIEmbeddingService(
            apiKey: "sk",
            baseURL: #require(URL(string: "https://api.example.com")),
            session: makeSession(),
            usageCallback: { tid, tok in await cap.set((tid, tok)) },
        )
        let tenantID = UUID()
        _ = try await svc.embed("x", tenantID: tenantID)
        let captured = await cap.value
        #expect(captured?.0 == tenantID)
        #expect(captured?.1 == 42)
    }
}
