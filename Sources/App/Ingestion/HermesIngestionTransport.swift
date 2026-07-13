import Foundation
import Hummingbird
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

protocol HermesIngestionTransport: Sendable {
    func ingest(tenantID: UUID, sourceURL: URL, contentType: String, instructions: String?) async throws -> Data
}

struct URLSessionHermesIngestionTransport: HermesIngestionTransport {
    let defaultBaseURL: URL
    let defaultAuthHeader: String?
    let endpointResolver: HermesEndpointResolver?
    let session: URLSession
    let logger: Logger

    func ingest(tenantID: UUID, sourceURL: URL, contentType: String, instructions: String?) async throws -> Data {
        let endpoint = try await endpoint(for: tenantID)
        let url = endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("ingestions")
        var request = URLRequest(url: url, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(tenantID.uuidString, forHTTPHeaderField: "X-Hermes-Session-Key")
        if let authHeader = endpoint.authHeader, !authHeader.isEmpty {
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(RequestBody(
            sourceURL: sourceURL.absoluteString,
            contentType: contentType,
            instructions: instructions
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.error("hermes ingestion endpoint failed status=\(status)")
            throw HTTPError(.badGateway, message: "Hermes ingestion endpoint failed")
        }
        return data
    }

    private func endpoint(for tenantID: UUID) async throws -> (baseURL: URL, authHeader: String?) {
        guard let endpointResolver else {
            return (defaultBaseURL, defaultAuthHeader)
        }
        let resolution = try await endpointResolver.resolve(tenantID: tenantID)
        return (
            resolution.baseURL,
            resolution.isUserOverride ? resolution.authHeader : defaultAuthHeader
        )
    }

    private struct RequestBody: Encodable {
        let sourceURL: String
        let contentType: String
        let instructions: String?

        enum CodingKeys: String, CodingKey {
            case sourceURL = "source_url"
            case contentType = "content_type"
            case instructions
        }
    }
}
