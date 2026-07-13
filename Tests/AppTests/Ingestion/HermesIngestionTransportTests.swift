@testable import App
import Foundation
import Hummingbird
import Logging
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite(.serialized, .disabled(if: IntegrationTestEnv.runIntegrationOnly))
struct HermesIngestionTransportTests {
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

    private final class Capture: @unchecked Sendable {
        var request: URLRequest?
    }

    private static func transport() -> URLSessionHermesIngestionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionHermesIngestionTransport(
            defaultBaseURL: URL(string: "https://hermes.test")!,
            defaultAuthHeader: "Bearer managed-key",
            endpointResolver: nil,
            session: URLSession(configuration: configuration),
            logger: Logger(label: "test.hermes.ingestion")
        )
    }

    @Test
    func `posts remote source to dedicated Hermes ingestion endpoint`() async throws {
        let capture = Capture()
        StubProtocol.handler = { request in
            capture.request = request
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"object":"hermes.ingestion.result","analysis":{}}"#.utf8)
            )
        }
        defer { StubProtocol.handler = nil }
        let tenantID = UUID()

        _ = try await Self.transport().ingest(
            tenantID: tenantID,
            sourceURL: #require(URL(string: "https://vault.test/v1/ingestion-sources/token")),
            contentType: "application/pdf",
            instructions: "Include page references."
        )

        let request = try #require(capture.request)
        #expect(request.url?.path == "/v1/ingestions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer managed-key")
        #expect(request.value(forHTTPHeaderField: "X-Hermes-Session-Key") == tenantID.uuidString)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["source_url"] == "https://vault.test/v1/ingestion-sources/token")
        #expect(json["content_type"] == "application/pdf")
        #expect(json["instructions"] == "Include page references.")
    }

    @Test
    func `non success response is surfaced as bad gateway`() async throws {
        StubProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("unavailable".utf8)
            )
        }
        defer { StubProtocol.handler = nil }

        await #expect(throws: HTTPError.self) {
            _ = try await Self.transport().ingest(
                tenantID: UUID(),
                sourceURL: #require(URL(string: "https://vault.test/source")),
                contentType: "image/jpeg",
                instructions: nil
            )
        }
    }
}
