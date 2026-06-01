import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking // URLSession / .shared live here on Linux
#endif

/// HER-43 (Slice 1) — a declarative connector capability. Given a tenant's
/// decrypted install config, it returns source URLs to stage. The plugin
/// layer hands those to the existing `ImportService.importLinks` pipeline
/// (stage → enrich → categorize → approve → compile), so a connector adds no
/// new ingestion path — it only knows how to talk to one external source.
protocol PluginConnector: Sendable {
    /// Catalog `binding` key this connector serves (see `PluginCatalog`).
    var binding: String { get }

    /// Pull source URLs for `tenantID` from the decrypted `config`.
    /// Throws `ConnectorError` for stable, mappable failures.
    func fetchURLs(config: [String: String], tenantID: UUID) async throws -> [String]
}

enum ConnectorError: Error, Equatable {
    /// A required config field was missing/empty at run time.
    case missingConfig(String)
    /// Upstream rejected the credential (e.g. HTTP 401/403).
    case unauthorized
    /// Upstream was unreachable or returned an unexpected status/body.
    case upstreamFailure(Int)
}

struct ConnectorHTTPResponse {
    let status: Int
    let body: Data
}

/// Minimal HTTP seam so connectors can be unit-tested with a stub. The default
/// implementation is `URLSessionConnectorHTTPClient`.
protocol ConnectorHTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse
}

struct URLSessionConnectorHTTPClient: ConnectorHTTPClient {
    let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }

    func get(url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return ConnectorHTTPResponse(status: status, body: data)
    }
}
