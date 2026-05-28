@testable import App
import Foundation
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HER-134 — LocalHermes adapter behaviour:
/// * resolver returning `nil` short-circuits with `.endpointMissing`,
/// * HTTP 404 from the container surfaces `.endpointMissing` so the chain
///   can advance to the next provider,
/// * a successful 200 with a 768-dim payload is zero-padded to 1536.
@Suite(.serialized)
struct LocalHermesEmbeddingServiceTests {
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
        override class func canInit(with _: URLRequest) -> Bool {
            handler != nil
        }

        override class func canonicalRequest(for r: URLRequest) -> URLRequest {
            r
        }

        override func startLoading() {
            guard let h = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            let (resp, data) = h(request)
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
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

    private func handle() -> HermesContainerHandle {
        HermesContainerHandle(
            tenantID: UUID(),
            containerName: "hermes-tenant-test",
            port: 8642,
            apiServerKey: "test-key",
            xaiConnectedAt: nil,
        )
    }

    @Test
    func `nil resolver → permanent endpointMissing`() async {
        let svc = LocalHermesEmbeddingService(
            resolveHandle: { _ in nil },
            session: makeSession(),
        )
        do {
            _ = try await svc.embed("x", tenantID: UUID())
            Issue.record("expected throw")
        } catch let e as EmbeddingProviderError {
            #expect(!e.isRecoverable)
            if case let .permanent(r) = e { #expect(r == .endpointMissing) } else { Issue.record("wrong case") }
        } catch {
            Issue.record("wrong type: \(error)")
        }
    }

    @Test
    func `404 from container → permanent endpointMissing`() async {
        StubProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        defer { StubProtocol.handler = nil }
        let h = handle()
        let svc = LocalHermesEmbeddingService(
            resolveHandle: { _ in h },
            session: makeSession(),
        )
        do {
            _ = try await svc.embed("x", tenantID: UUID())
            Issue.record("expected throw")
        } catch let e as EmbeddingProviderError {
            if case let .permanent(r) = e { #expect(r == .endpointMissing) } else { Issue.record("wrong case") }
        } catch {
            Issue.record("wrong type: \(error)")
        }
    }

    @Test
    func `768-dim response zero-pads to 1536`() async throws {
        let vec = (0 ..< 768).map { _ in Float(0.3) }
        let json: [String: Any] = ["data": [["embedding": vec]]]
        let body = try JSONSerialization.data(withJSONObject: json)
        StubProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }
        defer { StubProtocol.handler = nil }
        let h = handle()
        let svc = LocalHermesEmbeddingService(
            resolveHandle: { _ in h },
            session: makeSession(),
        )
        let v = try await svc.embed("x", tenantID: UUID())
        #expect(v.count == 1536)
        #expect(v.prefix(768).allSatisfy { $0 == 0.3 })
        #expect(v.suffix(768).allSatisfy { $0 == 0 })
    }
}
